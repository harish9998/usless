#Requires -Version 5.1
# worker.ps1 - remote job worker. Executes ONLY registered handlers from job.json.
# Runs on the RDP runner. Job dir: C:\RemoteWorkspace\jobs\<jobid>\
# Status transitions: queued -> accepted -> running -> succeeded|failed|cancelled|retry_wait
param(
  [Parameter(Mandatory=$true)][string]$JobId,
  [string]$Root = 'C:\RemoteWorkspace\jobs'
)
$ErrorActionPreference = 'Stop'
$dir = Join-Path $Root $JobId
$jobPath = Join-Path $dir 'job.json'
if (-not (Test-Path $jobPath)) { Write-Output "WORKER|ERR|no job.json at $jobPath"; exit 2 }
function Set-Prop($obj, [string]$name, $value) {
  if ($null -eq $obj.PSObject.Properties[$name]) { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
  else { $obj.$name = $value }
}
function Set-Status([string]$s, [string]$extra = '') {
  $j = Get-Content $jobPath -Raw | ConvertFrom-Json
  Set-Prop $j 'status' $s
  Set-Prop $j 'updatedAt' (Get-Date).ToUniversalTime().ToString('o')
  if ($extra) { Set-Prop $j 'lastError' $extra }
  [IO.File]::WriteAllText($jobPath, ($j | ConvertTo-Json -Depth 12))
  Write-Output "STATUS|$JobId|$s"
  if ($extra) { Write-Output "REASON|$extra" }
}
# Windows CRT-safe argument escaping (PS5.1 has no ProcessStartInfo.ArgumentList)
function Escape-Arg([string]$a) {
  if ($a -notmatch '[\s"]') { return $a }
  $b = $a -replace '(\\*)"','$1$1\"'
  $b = $b -replace '(\\+)$','$1$1'
  return '"' + $b + '"'
}
function Heartbeat { [IO.File]::WriteAllText((Join-Path $dir 'heartbeat.txt'), (Get-Date).ToUniversalTime().ToString('o')) }
$job = Get-Content $jobPath -Raw | ConvertFrom-Json
# Idempotency: never re-run a terminal job
if (@('succeeded','failed','cancelled') -contains $job.status) { Write-Output "WORKER|SKIP|terminal status=$($job.status)"; exit 0 }
if ($job.status -eq 'running') { Write-Output 'WORKER|SKIP|already running (possible duplicate submission)'; exit 0 }

Set-Status 'accepted'; Heartbeat
# Validate handler against registry (no arbitrary commands)
$allowed = @('ffmpeg','python','archive','build','docker')
$handler = "$($job.type)".ToLower()
if ($allowed -notcontains $handler) { Set-Status 'failed' "unregistered handler: $handler"; exit 3 }
if ($null -eq $job.arguments -or $job.arguments -isnot [array]) { Set-Status 'failed' 'arguments must be an array'; exit 3 }
if ($null -eq $job.arguments) { $job.arguments = @() }
# Resolve exe from allowlist - never from job payload
$exeMap = @{
  ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
  python = (Get-Command python -ErrorAction SilentlyContinue).Source
  archive = $null
  build  = $null
  docker = (Get-Command docker -ErrorAction SilentlyContinue).Source
}
$exe = $exeMap[$handler]
if ($handler -in @('archive','build')) { $exe = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
if (-not $exe) { Set-Status 'failed' "handler exe unavailable: $handler"; exit 3 }
# Path safety: all referenced paths must stay inside job dir
foreach ($a in $job.arguments) {
  if ("$a" -match '^[A-Za-z]:\\' -and -not "$a".StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) {
    Set-Status 'failed' "path outside job dir rejected: $a"; exit 3
  }
}
$timeoutSec = if ($job.timeoutSec) { [int]$job.timeoutSec } else { 1800 }
$log = Join-Path $dir 'log.txt'
Set-Status 'running'; Heartbeat
try {
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = $exe; $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $dir
  $psi.Arguments = (($job.arguments | ForEach-Object { Escape-Arg ([string]$_) }) -join ' ')
  $p = [System.Diagnostics.Process]::Start($psi)
  # Read both streams asynchronously to avoid pipe-buffer deadlock on chatty tools (ffmpeg)
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($timeoutSec * 1000)) { $p.Kill(); throw "timeout after ${timeoutSec}s" }
  $out = $outTask.Result; $err = $errTask.Result
  [IO.File]::WriteAllText($log, "STDOUT:`n$out`nSTDERR:`n$err")
  Heartbeat
  if ($p.ExitCode -eq 0) {
    # output manifest: list files produced in job dir (excluding job/log/heartbeat)
    $outs = @(Get-ChildItem $dir -File | Where-Object { $_.Name -notin @('job.json','log.txt','heartbeat.txt','checkpoint.json') } | Select-Object -ExpandProperty Name)
    $j = Get-Content $jobPath -Raw | ConvertFrom-Json
    $j.outputs = $outs
    [IO.File]::WriteAllText($jobPath, ($j | ConvertTo-Json -Depth 12))
    Set-Status 'succeeded'
  } else {
    $tries = 0; if ($job.retries) { $tries = [int]$job.retries }
    if ($tries -gt 0) {
      $j = Get-Content $jobPath -Raw | ConvertFrom-Json; $j.retries = $tries - 1
      [IO.File]::WriteAllText($jobPath, ($j | ConvertTo-Json -Depth 12))
      Set-Status 'retry_wait' "exit=$($p.ExitCode)"
    } else { Set-Status 'failed' "exit=$($p.ExitCode)" }
  }
} catch {
  [IO.File]::AppendAllText($log, "`nEXCEPTION: $($_.Exception.Message)")
  Set-Status 'failed' $_.Exception.Message
}
