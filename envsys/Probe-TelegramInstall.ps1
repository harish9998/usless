#Requires -Version 5.1
# Probe-TelegramInstall.ps1 - BOUNDED feasibility probe for the Telegram Drive gate.
# Zero secrets, no Telegram account needed. Determines ONLY:
#   1. Can the pinned NSIS installer download + silent-install on a fresh runner?
#   2. Does the app process start and stay alive without an interactive login?
#   3. What answers 127.0.0.1:8550 (refused = REST not started, expected unsigned-in)?
# It does NOT sign in, enable REST, or publish anything. Verdict lines decide
# whether the seeded-session architecture is worth pursuing.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File Probe-TelegramInstall.ps1
#
# Machine-readable stdout: PROBE|STEP=<s>|STATUS=<...>|DETAIL=<...>
# Final: PROBE|VERDICT=<INSTALL-BLOCKED|LAUNCH-BLOCKED|PORT-CLOSED|HEALTH-200|HEALTH-OTHER>
# Exit 0 = verdict delivered. Exit 1 = probe infrastructure error (not a verdict).
param([string]$InstallerUrl = 'https://github.com/caamer20/Telegram-Drive/releases/download/v3.5.0/Telegram.Drive_3.5.0_x64-setup.exe',
  [string]$ExpectProduct = 'Telegram Drive',
  [int]$PollSeconds = 360)
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source this file: execute it.' }
function Verdict([string]$v, [string]$d) { Write-Output "PROBE|VERDICT=$v|DETAIL=$d"; exit 0 }
function Step([string]$s, [string]$st, [string]$d) { Write-Output "PROBE|STEP=$s|STATUS=$st|DETAIL=$d" }
try {
  $work = Join-Path $env:TEMP 'tgprobe'
  New-Item -ItemType Directory -Path $work -Force | Out-Null
  $inst = Join-Path $work 'td-setup.exe'

  Step 'Download' 'START' $InstallerUrl
  try { Invoke-WebRequest -Uri $InstallerUrl -OutFile $inst -TimeoutSec 600 -ErrorAction Stop }
  catch { Step 'Download' 'FAIL' $_.Exception.Message; Verdict 'INSTALL-BLOCKED' 'download failed' }
  $size = (Get-Item -LiteralPath $inst).Length
  $mz = [System.IO.File]::ReadAllBytes($inst)[0..1]
  if (($size -lt 10MB) -or ($mz[0] -ne 0x4D) -or ($mz[1] -ne 0x5A)) {
    Step 'Download' 'FAIL' "size=$size magic=$($mz -join ',')"
    Verdict 'INSTALL-BLOCKED' 'installer corrupt or truncated'
  }
  Step 'Download' 'SUCCESS' "size=$size"

  Step 'Install' 'START' 'nsis /S'
  $p = Start-Process -FilePath $inst -ArgumentList '/S' -Wait -PassThru -NoNewWindow
  Step 'Install' 'EXIT' "code=$($p.ExitCode)"
  if ($p.ExitCode -ne 0) { Step 'Install' 'FAIL' "exit=$($p.ExitCode)"; Verdict 'INSTALL-BLOCKED' "silent install exit $($p.ExitCode)" }
  # NSIS may install per-user (LOCALAPPDATA\Programs) when not elevated; search
  # machine + user locations plus the uninstall registry before concluding.
  $roots = @('C:\Program Files', (Join-Path $env:LOCALAPPDATA 'Programs'))
  $exe = $null
  foreach ($rt in $roots) {
    if (-not (Test-Path -LiteralPath $rt)) { continue }
    $exe = Get-ChildItem -LiteralPath $rt -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -like '*elegram*Drive*' } | Select-Object -First 1
    if ($exe) { break }
  }
  if (-not $exe) {
    foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) {
      if (-not (Test-Path -LiteralPath $hive)) { continue }
      foreach ($k in (Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue)) {
        $dn = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).DisplayName
        if ($dn -like '*elegram*Drive*') {
          $loc = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).InstallLocation
          if ($loc) { $loc = ([string]$loc).Trim().Trim('"') }
          Step 'Install' 'REGHIT' "$dn @ $loc"
          if ($loc -and (Test-Path -LiteralPath $loc)) {
            $exe = Get-ChildItem -LiteralPath $loc -Filter '*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($exe) { break }
          }
        }
      }
      if ($exe) { break }
    }
  }
  if (-not $exe) { Step 'Install' 'FAIL' 'no installed exe found'; Verdict 'INSTALL-BLOCKED' 'installed exe not found' }
  Step 'Install' 'SUCCESS' $exe.FullName

  Step 'Launch' 'START' $exe.FullName
  $app = Start-Process -FilePath $exe.FullName -PassThru
  Start-Sleep -Seconds 20
  if ($app.HasExited) { Step 'Launch' 'FAIL' "exit=$($app.ExitCode)"; Verdict 'LAUNCH-BLOCKED' 'process died within 20s' }
  Step 'Launch' 'SUCCESS' "pid=$($app.Id)"

  Step 'Health' 'START' 'poll 127.0.0.1:8550/api/v1/health'
  $deadline = (Get-Date).AddSeconds($PollSeconds)
  $lastErr = 'none'
  while ((Get-Date) -lt $deadline) {
    if ($app.HasExited) { Step 'Health' 'FAIL' 'app died during poll'; Verdict 'LAUNCH-BLOCKED' 'process died while polling' }
    try {
      $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8550/api/v1/health' -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
      Step 'Health' 'SUCCESS' "http=$($r.StatusCode) body=$($r.Content)"
      try { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue } catch {}
      Verdict 'HEALTH-200' 'REST port answers without sign-in (unexpected; record exact body above)'
    } catch {
      $lastErr = $_.Exception.Message
      if ($_.Exception.Message -match '401|403') {
        Step 'Health' 'SUCCESS' 'auth gate up (unexpected without enable)'
        try { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue } catch {}
        Verdict 'HEALTH-OTHER' 'port answers with auth gate'
      }
    }
    Start-Sleep -Seconds 15
  }
  try { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue } catch {}
  Step 'Health' 'TIMEOUT' $lastErr
  $dataDir = Join-Path $env:APPDATA 'com.cameronamer.telegramdrive'
  $dirState = if (Test-Path -LiteralPath $dataDir) { 'app-data dir created' } else { 'no app-data dir' }

  # Phase 2 (still zero secrets): prove config-seeded REST autostart. Write
  # api_settings.json with enabled:true + hash of a DUMMY key, relaunch, poll.
  # A 200 (or any HTTP answer) proves the file-seeded autostart path headless;
  # only the Telegram sign-in half would remain for a seeded session.
  Step 'Seed' 'START' 'api_settings.json enabled:true + dummy key hash'
  if (-not (Test-Path -LiteralPath $dataDir)) {
    Verdict 'PORT-CLOSED' "no listener in ${PollSeconds}s; $dirState"
  }
  $names = @(Get-ChildItem -LiteralPath $dataDir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
  Step 'Seed' 'APPDATA' ($names -join ',')
  $dummyHash = (([System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes('probe-dummy-key'))) | ForEach-Object { $_.ToString('x2') }) -join ''
  @{ enabled = $true; port = 8550; key_hash = $dummyHash } | ConvertTo-Json -Compress |
    Out-File -LiteralPath (Join-Path $dataDir 'api_settings.json') -Encoding ascii -NoNewline
  Step 'Seed' 'WRITTEN' 'enabled:true port:8550 key_hash:sha256(probe-dummy-key)'
  $app2 = Start-Process -FilePath $exe.FullName -PassThru
  Start-Sleep -Seconds 25
  if ($app2.HasExited) { Verdict 'LAUNCH-BLOCKED' 'process died after seeding (exit on relaunch)' }
  $deadline2 = (Get-Date).AddSeconds(180)
  while ((Get-Date) -lt $deadline2) {
    if ($app2.HasExited) { Verdict 'LAUNCH-BLOCKED' 'process died during seeded poll' }
    try {
      $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8550/api/v1/health' -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
      Step 'Seed' 'HEALTH' "http=$($r.StatusCode) body=$($r.Content)"
      try { Stop-Process -Id $app2.Id -Force -ErrorAction SilentlyContinue } catch {}
      Verdict 'HEALTH-200-SEEDED' 'seeded api_settings.json autostarts REST headless; only Telegram sign-in remains'
    } catch {
      $lastErr = $_.Exception.Message
      if ($_.Exception.Message -match '401|403') {
        try { Stop-Process -Id $app2.Id -Force -ErrorAction SilentlyContinue } catch {}
        Verdict 'HEALTH-OTHER' 'seeded REST answers with auth gate'
      }
    }
    Start-Sleep -Seconds 15
  }
  try { Stop-Process -Id $app2.Id -Force -ErrorAction SilentlyContinue } catch {}
  Verdict 'PORT-CLOSED-SEEDED' "seeded config did not open REST; last=$lastErr"
} catch {
  Write-Output "PROBE|STEP=Probe|STATUS=ERROR|DETAIL=$($_.Exception.Message)"
  exit 1
}
