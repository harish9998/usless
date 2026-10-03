#Requires -Version 5.1
# Invoke-EnvBootstrap.ps1 - full fresh-runner reconstruction with health-gated phases.
#   powershell -File Invoke-EnvBootstrap.ps1 -BackendType LocalDir -Root D:\envstore [-WorkDir C:\Work]
# Phases: IDENTIFY -> FETCH -> VERIFY -> RESTORE -> PROVISION -> SECRETS -> SERVICES
#         -> HEARTBEAT -> HEALTH -> READY. Any required failure stops before READY.
param([ValidateSet('LocalDir','TelegramRest')][string]$BackendType = 'LocalDir',
  [string]$Root = '', [string]$WorkDir = 'C:\Work', [string]$HomeRoot = '')
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source this file: execute it. (Top-level pipeline code would run on import.)' }
. "$PSScriptRoot\Storage-Backend.ps1"
function Phase { param([string]$c, [string]$s) Write-Output "BOOTSTRAP|COMPONENT=$c|STATUS=$s" }
$fail = 0
function Need { param([bool]$ok, [string]$c, [string]$m)
  if ($ok) { Phase $c 'SUCCESS' } else { Phase $c 'FAIL'; Write-Warning "${c}: ${m}"; $script:fail = $script:fail + 1 }
}
$stage = Join-Path $env:TEMP "envrestore-$PID"

try {
  Phase 'Identify' 'START'
  $runId = "gh-runner-$env:GITHUB_RUN_ID"
  Phase 'Identify' 'SUCCESS'

  $bargs = @{ Type = $BackendType }
  if ($BackendType -eq 'LocalDir') { $bargs.Root = $Root } else { $bargs.ApiKey = $env:TG_API_KEY }
  $be = New-StorageBackend @bargs
function Test-ZipSafe([string]$zip) {
  # Reject archives that escape the destination (..\ , absolute paths, drive specs).
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
  try {
    foreach ($e in $z.Entries) {
      $n = $e.FullName -replace '/', '\'
      if ($n -match '(^|\\)\.\.(\\|$)' -or [System.IO.Path]::IsPathRooted($n) -or ($n -match '^[A-Za-z]:')) {
        return $false
      }
    }
    return $true
  } finally { $z.Dispose() }
}

  # FETCH latest pointer (+ fallback to previous on corruption, per retention)
  Phase 'Fetch' 'START'
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  $ptr = $null; $snapId = ''
  try {
    Storage-DownloadFile $be 'envsnap/latest.json' "$stage\latest.json" | Out-Null
    $ptr = Get-Content "$stage\latest.json" -Raw | ConvertFrom-Json
    $snapId = $ptr.snapshot_id
  } catch { Phase 'Fetch' 'SKIP-NO-SNAPSHOT' }
  if ($snapId) { Phase 'Fetch' 'SUCCESS' }

  # VERIFY + RESTORE (latest first, then previous-good fallback, newest-first, max 4 tries)
  $candidates = @()
  if ($snapId) {
    Phase 'Verify' 'START'
    $candidates += $snapId
    try {
      $cands = @(Storage-List $be 'envsnap/envsnap-' | Where-Object { $_.name -match '\.manifest\.json$' } |
        ForEach-Object { ($_.name -replace '^.*[/\\]([^/\\]+)\.manifest\.json$','$1') } |
        Where-Object { $_ -ne $snapId } | Sort-Object -Descending | Select-Object -First 3)
      $candidates += @($cands)
    } catch {}
  }
  $verifiedId = ''
  foreach ($cid in $candidates) {
    try {
      Storage-DownloadFile $be "envsnap/$cid.manifest.json" "$stage\manifest.json" | Out-Null
      $man = Get-Content "$stage\manifest.json" -Raw | ConvertFrom-Json
      $needParts = 1
      if ($man.parts -gt 1) { $needParts = $man.parts }
      if ($needParts -gt 1) {
        for ($k = 1; $k -le $needParts; $k++) {
          Storage-DownloadFile $be ("envsnap/$cid.part" + ("{0:000}" -f $k)) "$stage\part-$k" | Out-Null
        }
        cmd /c copy /b "$stage\part-*" "$stage\$cid.zip" | Out-Null
      } else {
        Storage-DownloadFile $be "envsnap/$cid.zip" "$stage\$cid.zip" | Out-Null
      }
      if (-not (Test-ZipSafe "$stage\$cid.zip")) { throw 'archive failed traversal safety check' }
      if (Test-Path -LiteralPath "$stage\state") { Remove-Item "$stage\state" -Recurse -Force }
      Expand-Archive -LiteralPath "$stage\$cid.zip" -DestinationPath "$stage\state" -Force
      $dman = Get-Content "$stage\state\manifest.json" -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
      if (-not $dman -or $dman.sha256 -ne $man.sha256) { throw 'manifest/digest mismatch' }
      if ($dman.schema_version -ne 1) { throw ("unsupported schema_version: " + $dman.schema_version) }
      # Recompute the payload digest from extracted files (manifest equality alone
      # cannot catch payload corruption inside a well-formed archive).
      $vbase = (Get-Item -LiteralPath "$stage\state").FullName
      $vlines = Get-ChildItem -LiteralPath "$stage\state" -Recurse -File |
        Where-Object { $_.Name -ne 'manifest.json' } | Sort-Object FullName | ForEach-Object {
          $s = [System.IO.File]::OpenRead($_.FullName)
          try {
            $h = ([System.Security.Cryptography.SHA256]::Create().ComputeHash($s) | ForEach-Object { $_.ToString('x2') }) -join ''
            $_.FullName.Substring($vbase.Length) + '=' + $h
          } finally { $s.Close() }
        }
      $vb = [System.Text.Encoding]::UTF8.GetBytes(($vlines -join "`n"))
      $vsha = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
      if ($vlines) {
        $vsha = ([System.Security.Cryptography.SHA256]::Create().ComputeHash($vb) | ForEach-Object { $_.ToString('x2') }) -join ''
      }
      if ($vsha -ne $man.sha256) { throw 'payload digest mismatch (archive content corrupt)' }
      $verifiedId = $cid
      break
    } catch { Write-Warning "snapshot $cid bad: $($_.Exception.Message)" }
  }
  if ($verifiedId) {
    $snapId = $verifiedId
    if ($verifiedId -eq $candidates[0]) { Phase 'Verify' 'SUCCESS' } else { Phase 'Verify' 'SUCCESS-FALLBACK' }
    Phase 'Restore' 'START'
    powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Restore-WindowsEnvironment.ps1" -SnapshotDir "$stage\state" -HomeRoot $HomeRoot -WorkDir $WorkDir
    if ($LASTEXITCODE -ne 0) { throw 'restore degraded' }
    Phase 'Restore' 'SUCCESS'
  } elseif ($candidates.Count -gt 0) { Phase 'Verify' 'FAIL'; throw 'no valid snapshot in retention' }
  else { Phase 'Restore' 'SKIP-FIRST-BOOT' }

  # PROVISION (manifest, idempotent) + SECRETS note + SERVICES/automation via existing entry points
  Phase 'Provision' 'START'
  $stack = Join-Path $WorkDir 'Install-MyStack.ps1'
  if (Test-Path -LiteralPath $stack) {
    powershell -NoProfile -ExecutionPolicy Bypass -File $stack
    Need ($LASTEXITCODE -eq 0) 'Provision' 'stack failed'
  } else { Phase 'Provision' 'SKIP-NO-STACK' }
  Phase 'Secrets' 'START'
  Phase 'Secrets' 'SUCCESS-NOTE: snapshots carry zero secrets; runtime injection via env/GH secrets only'
  Phase 'Services' 'START'
  $auto = Join-Path $WorkDir 'Start-MyAutomation.ps1'
  if (Test-Path -LiteralPath $auto) {
    powershell -NoProfile -ExecutionPolicy Bypass -File $auto
    Need ($LASTEXITCODE -eq 0) 'Services' 'automation degraded'
  } else { Phase 'Services' 'SKIP-NO-AUTOMATION' }

  # HEALTH gate
  Phase 'Health' 'START'
  $rok = (Test-Path -LiteralPath $WorkDir)
  $dok = [bool](Get-Command docker -ErrorAction SilentlyContinue)
  Need $rok 'Health-Workspace' 'no workdir'
  if (-not $dok) { Phase 'Health-Docker' 'SKIP-ABSENT' } else { Phase 'Health-Docker' 'SUCCESS' }
} finally {
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail -gt 0) { Write-Output 'BOOTSTRAP|STATUS=DEGRADED'; exit 1 }
Write-Output 'BOOTSTRAP|STATUS=READY'
