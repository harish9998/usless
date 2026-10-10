#Requires -Version 5.1
# Enable-TelegramRest.ps1 - seeds a Telegram Drive REST endpoint from OUT-OF-BAND
# secrets and verifies it. This is the production counterpart of the install probe.
#
# Reads (process env only, never files/logs/snapshots):
#   TG_API_KEY     (required) REST key plaintext; only its SHA-256 goes to disk.
#   TG_SESSION_DIR (optional) directory holding VERBATIM session files exported
#                  from a signed-in machine: telegram.session[.wal/.shm] and
#                  config.json (tauri-store with api_id). Absent = REST-only
#                  mode: REST comes up, Telegram reports SIGNED-OUT.
#
# Does: locate/install-check app -> place session files (allowlist only) ->
#   write api_settings.json {enabled,port,key_hash} -> (re)launch app ->
#   poll /health -> one authenticated GET /files?limit=1 (code only, bodies
#   never printed: they may contain user file names).
#
#   powershell -File Enable-TelegramRest.ps1 [-AppExe ...] [-DataDir ...] [-Port 8550]
#
# Verdict stdout: TELEGRAM|REST=UP|DOWN  TELEGRAM|SESSION=SIGNED-IN|SIGNED-OUT|UNKNOWN
# Exit 0 = REST up (session state reported honestly). Exit 1 = REST not up.
# Session files are live credentials: never snapshot, archive, or print them.
param([string]$AppExe = '', [string]$DataDir = '', [int]$Port = 8550, [int]$PollSeconds = 240)
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source this file: execute it.' }
function Phase([string]$c, [string]$s, [string]$d = '') { Write-Output "TELEGRAM|COMPONENT=$c|STATUS=$s|DETAIL=$d" }
function Get-Sha256Text([string]$t) {
  $b = [System.Text.Encoding]::UTF8.GetBytes($t)
  return (([System.Security.Cryptography.SHA256]::Create().ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) -join '')
}

$key = $env:TG_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) { Phase 'Config' 'FAIL' 'TG_API_KEY env empty'; exit 1 }
if (-not $DataDir) { $DataDir = Join-Path $env:APPDATA 'com.cameronamer.telegramdrive' }
if (-not $AppExe) {
  # NSIS installs per-user here when not elevated; mirror the probe's resolution:
  # exact spots, then per-machine/user trees, then the uninstall registry.
  $exact = @((Join-Path $env:LOCALAPPDATA 'Telegram Drive\app.exe'))
  foreach ($x in $exact) { if (Test-Path -LiteralPath $x) { $AppExe = $x; break } }
  if (-not $AppExe) {
    foreach ($rt in @((Join-Path $env:LOCALAPPDATA 'Programs'), 'C:\Program Files')) {
      if (-not (Test-Path -LiteralPath $rt)) { continue }
      $hit = Get-ChildItem -LiteralPath $rt -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*elegram*Drive*' } | Select-Object -First 1
      if ($hit) { $AppExe = $hit.FullName; break }
    }
  }
  if (-not $AppExe) {
    foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
      if (-not (Test-Path -LiteralPath $hive)) { continue }
      foreach ($k in (Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue)) {
        $dn = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).DisplayName
        if ($dn -like '*elegram*Drive*') {
          $loc = ([string](Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).InstallLocation).Trim().Trim('"')
          if ($loc -and (Test-Path -LiteralPath $loc)) {
            $hit = Get-ChildItem -LiteralPath $loc -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $AppExe = $hit.FullName; break }
          }
        }
      }
      if ($AppExe) { break }
    }
  }
}
if (-not $AppExe -or -not (Test-Path -LiteralPath $AppExe)) {
  Phase 'App' 'FAIL' 'Telegram Drive exe not found (install it first)'; exit 1
}
Phase 'App' 'FOUND' $AppExe

# Session files: allowlist only, never enumerated by content.
$allowed = @('telegram.session', 'telegram.session-wal', 'telegram.session-shm', 'config.json')
$sessionMode = 'REST-ONLY'
if ($env:TG_SESSION_DIR -and (Test-Path -LiteralPath $env:TG_SESSION_DIR)) {
  New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
  $n = 0
  foreach ($leaf in $allowed) {
    $src = Join-Path $env:TG_SESSION_DIR $leaf
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $DataDir $leaf) -Force; $n++ }
  }
  if ($n -gt 0) { $sessionMode = "SEEDED-$n-files" } else { Phase 'Session' 'WARN' 'session dir had no allowlisted files' }
} else { Phase 'Session' 'SKIP' 'TG_SESSION_DIR unset (REST-only mode)' }

@{ enabled = $true; port = $Port; key_hash = (Get-Sha256Text $key) } | ConvertTo-Json -Compress |
  Out-File -LiteralPath (Join-Path $DataDir 'api_settings.json') -Encoding ascii -NoNewline
Phase 'Config' 'WRITTEN' "enabled:true port:$Port keylen:$($key.Length) mode:$sessionMode"

Get-Process -ErrorAction SilentlyContinue | Where-Object {
  try { $_.Path -like '*elegram*Drive*' } catch { $false }
} | ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }
Start-Sleep -Seconds 3
$app = Start-Process -FilePath $AppExe -PassThru
Start-Sleep -Seconds 25
if ($app.HasExited) { Phase 'Launch' 'FAIL' 'died within 25s'; exit 1 }
Phase 'Launch' 'ALIVE' "pid=$($app.Id)"

$health = "http://127.0.0.1:$Port/api/v1/health"
$deadline = (Get-Date).AddSeconds($PollSeconds)
$up = $false
while ((Get-Date) -lt $deadline) {
  if ($app.HasExited) { Phase 'Launch' 'FAIL' 'died while polling'; exit 1 }
  try {
    $r = Invoke-WebRequest -Uri $health -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    if ($r.StatusCode -eq 200) { $up = $true; break }
  } catch {}
  Start-Sleep -Seconds 15
}
if (-not $up) { Phase 'REST' 'DOWN' "no /health in ${PollSeconds}s"; exit 1 }
Phase 'REST' 'UP' '/health 200'

# Authenticated probe: status code only, body never printed.
$session = 'UNKNOWN'
try {
  $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/v1/files?limit=1" -TimeoutSec 30 `
    -UseBasicParsing -Headers @{ 'X-API-Key' = $key } -ErrorAction Stop
  if ($r.StatusCode -eq 200) { $session = 'SIGNED-IN' } else { $session = "HTTP-$($r.StatusCode)" }
} catch {
  $msg = $_.Exception.Message
  if ($msg -match '401|403') { $session = 'KEY-REJECTED' }
  elseif ($msg -match '500') { $session = 'SIGNED-OUT' }
  else { $session = 'PROBE-ERROR' }
}
Write-Output "TELEGRAM|REST=UP|SESSION=$session"
if ($session -eq 'KEY-REJECTED') { exit 1 }
exit 0
