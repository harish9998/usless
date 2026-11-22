#Requires -Version 5.1
# remote-jobs.ps1 - local dispatcher for the remote compute fabric.
# Jobs are persisted locally (survives runner destruction) under ~/.usless/jobs.
# Usage:
#   remote-jobs.ps1 -Action new -JobType ffmpeg -Args @('-i','in.mp4','out.mp4') -Inputs @('C:\vids\in.mp4')
#   remote-jobs.ps1 -Action submit -JobId <id> [-Target 1] [-AllowDispatch]
#   remote-jobs.ps1 -Action list|status|logs|pull|cancel|recover
param(
  [ValidateSet('new','submit','list','status','logs','pull','cancel','recover')][string]$Action = 'list',
  [string]$JobType, [string[]]$Args = @(), [string[]]$Inputs = @(),
  [string]$JobId, [string]$Target = '1', [switch]$AllowDispatch,
  [int]$TimeoutSec = 1800, [int]$Retries = 0,
  [string]$Registry = "$env:USERPROFILE\.usless\jobs"
)
. (Join-Path $PSScriptRoot 'remote-common.ps1')
New-Item -ItemType Directory $Registry -Force | Out-Null
function Load-Jobs { @(Get-ChildItem $Registry -Filter '*.json' -File | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }) }
function Save-Job($j) { Write-JsonAtomic (Join-Path $Registry "$($j.id).json") $j }
function Find-Job($id) { $p = Join-Path $Registry "$id.json"; if (Test-Path $p) { Get-Content $p -Raw | ConvertFrom-Json } else { throw "Job not found: $id" } }
$allowedTypes = @('ffmpeg','python','archive','build','docker')

switch ($Action) {
  'new' {
    if ($allowedTypes -notcontains $JobType) { throw "Unregistered job type '$JobType'. Allowed: $($allowedTypes -join ', ')" }
    $id = "job-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0,6))"
    $j = [ordered]@{
      id=$id; type=$JobType; createdAt=(Get-Date).ToUniversalTime().ToString('o'); updatedAt=(Get-Date).ToUniversalTime().ToString('o')
      priority=1; status='queued'; arguments=$Args; inputManifest=@($Inputs); outputs=@()
      timeoutSec=$TimeoutSec; retries=$Retries; attempt=0; checksums=@{}; lastError=''
    }
    # checksum inputs
    foreach ($f in $Inputs) { if (Test-Path $f) { $j.checksums[(Split-Path $f -Leaf)] = Get-FileSha256 $f } else { throw "Input missing: $f" } }
    Save-Job $j
    Write-Output "JOB|created=$id|type=$JobType|inputs=$($Inputs.Count)"
  }
  'submit' {
    $j = Find-Job $JobId
    if (@('succeeded','running','accepted') -contains $j.status) { Write-Output "SUBMIT|skip|status=$($j.status)"; exit 0 }
    $runner = Resolve-Runner -Target $Target -AllowDispatch:$AllowDispatch
    Write-Output "SUBMIT|run=$($runner.RunId)|ip=$($runner.Ip)|job=$JobId"
    New-Item -ItemType Directory "$env:TEMP\_job-$JobId" -Force | Out-Null
    $stage = "$env:TEMP\_job-$JobId"
    $j.attempt++; $j.status='queued'; $j.updatedAt=(Get-Date).ToUniversalTime().ToString('o'); Save-Job $j
    Copy-Item (Join-Path $Registry "$JobId.json") "$stage\job.json" -Force
    foreach ($f in $j.inputManifest) { Copy-Item $f $stage -Force }
    Copy-ToRunner $runner $stage "C:\RemoteWorkspace\jobs\$JobId"
    $remoteScript = "powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\RemoteWorkspace\worker\worker.ps1' -JobId '$JobId'"
    $out = & ssh @(New-SshArgs $runner 30) $remoteScript 2>&1
    Write-Output ($out -join "`n")
    # Persist runner identity + final status so status/logs/pull work after submission.
    function Set-Prop($obj,[string]$n,$v){ if ($null -eq $obj.PSObject.Properties[$n]) { $obj | Add-Member -NotePropertyName $n -NotePropertyValue $v } else { $obj.$n = $v } }
    Set-Prop $j 'runnerIp' $runner.Ip; Set-Prop $j 'runnerUser' $runner.User; Set-Prop $j 'runnerRunId' $runner.RunId
    $remoteState = Invoke-RemoteScript $runner "Get-Content 'C:\RemoteWorkspace\jobs\$JobId\job.json' -Raw" 2>&1 | Out-String
    try {
      $rj = $remoteState | ConvertFrom-Json
      $j.status = $rj.status; $j.outputs = @($rj.outputs); $j.updatedAt = $rj.updatedAt
    } catch { $j.status = 'accepted' }
    Save-Job $j
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
  }
  'list' { Load-Jobs | ForEach-Object { "JOB|{0}|{1}|{2}|attempt={3}" -f $_.id,$_.type,$_.status,$_.attempt } }
  'status' {
    $j = Find-Job $JobId
    if (-not $j.runnerIp) { Write-Output "STATUS|$JobId|$($j.status)|not-submitted"; exit 0 }
    $r = [pscustomobject]@{ Ip=$j.runnerIp; User=$j.runnerUser; RunId=$j.runnerRunId }
    try {
      $remote = Invoke-RemoteScript $r "Get-Content 'C:\RemoteWorkspace\jobs\$JobId\job.json' -Raw" | Out-String
      $rj = $remote | ConvertFrom-Json
      $j.status = $rj.status; $j.updatedAt = $rj.updatedAt; $j.outputs = $rj.outputs; Save-Job $j
    } catch { Write-Output "STATUS|$JobId|$($j.status)|runner-unreachable (local copy)" }
    Write-Output "STATUS|$JobId|$($j.status)|outputs=$($j.outputs.Count)"
  }
  'logs' {
    $j = Find-Job $JobId
    if (-not $j.runnerIp) { Write-Output 'LOGS|not-submitted'; exit 0 }
    $r = [pscustomobject]@{ Ip=$j.runnerIp; User=$j.runnerUser }
    Invoke-RemoteScript $r "Get-Content 'C:\RemoteWorkspace\jobs\$JobId\log.txt' -Raw -ErrorAction SilentlyContinue" | ForEach-Object { Write-Output $_ }
  }
  'pull' {
    $j = Find-Job $JobId
    if (-not $j.runnerIp) { throw 'Job was never submitted' }
    if ($j.status -ne 'succeeded') { throw "Job status=$($j.status) - only succeeded jobs can be pulled" }
    $r = [pscustomobject]@{ Ip=$j.runnerIp; User=$j.runnerUser }
    $dest = "$env:USERPROFILE\Downloads\RDP-Inbox\$JobId"; New-Item -ItemType Directory $dest -Force | Out-Null
    foreach ($o in $j.outputs) { Copy-FromRunner $r "C:\RemoteWorkspace\jobs\$JobId\$o" $dest; Write-Output "PULLED|$o" }
    Write-Output "PULL|dir=$dest"
  }
  'cancel' {
    $j = Find-Job $JobId; $j.status='cancelled'; $j.updatedAt=(Get-Date).ToUniversalTime().ToString('o'); Save-Job $j
    if ($j.runnerIp) {
      $r = [pscustomobject]@{ Ip=$j.runnerIp; User=$j.runnerUser }
      Invoke-RemoteScript $r "Get-CimInstance Win32_Process | Where-Object { `$_.CommandLine -match '$JobId' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }" | Out-Null
    }
    Write-Output "CANCEL|$JobId"
  }
  'recover' {
    $recoverable = @(Load-Jobs | Where-Object { @('running','retry_wait','accepted','queued') -contains $_.status -and $_.attempt -gt 0 -and $_.attempt -le 3 })
    if ($recoverable.Count -eq 0) { Write-Output 'RECOVER|no interrupted jobs'; exit 0 }
    foreach ($j in $recoverable) {
      Write-Output "RECOVER|$($j.id)|from=$($j.status)|attempt=$($j.attempt)"
      $j.status = 'retry_wait'; Save-Job $j
      & powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -Action submit -JobId $j.id -Target $Target -AllowDispatch:$AllowDispatch
    }
  }
}
