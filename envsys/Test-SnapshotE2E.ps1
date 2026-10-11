#Requires -Version 5.1
# Test-SnapshotE2E.ps1 - Runner A side: publish a synthetic snapshot through the
# REAL Telegram backend, then independently verify it (download + digest).
# Env: TG_API_KEY (required), TG_SESSION_B64[_N] (required).
# The snapshot ID is printed as SNAPSHOT|<sid> for Runner B. Synthetic fixture
# only; the shared envsnap/ area holds exactly one test snapshot afterwards.
# Exit 0 = published + independently verified. Exit 1 = anything failed.
param()
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source this file: execute it.' }
$Here = $PSScriptRoot
$script:pass = 0; $script:fail = 0
function Test-Result {
  param([string]$Name, [string]$Status, [string]$Detail = '')
  Write-Output "TEST|NAME=$Name|STATUS=$Status|DETAIL=$Detail"
  if ($Status -eq 'PASS') { $script:pass++ } else { $script:fail++ }
}
function Fail([string]$n, [string]$d) { Test-Result $n 'FAIL' $d; throw "[$n] $d" }
function Temp-Base { $t = $env:TEMP; if (-not $t) { $t = $env:TMPDIR }; if (-not $t) { $t = '/tmp' }; return $t }
function Get-Sha256File([string]$p) {
  $s = [System.IO.File]::OpenRead($p)
  try { return (([System.Security.Cryptography.SHA256]::Create().ComputeHash($s) | ForEach-Object { $_.ToString('x2') }) -join '') }
  finally { $s.Close() }
}

try {
  if ([string]::IsNullOrWhiteSpace($env:TG_API_KEY)) { Fail 'S00-secrets' 'TG_API_KEY empty' }
  $b64 = $env:TG_SESSION_B64
  if ([string]::IsNullOrWhiteSpace($b64)) {
    $parts = @()
    for ($k = 1; $k -le 9; $k++) {
      $c = [Environment]::GetEnvironmentVariable("TG_SESSION_B64_$k")
      if ([string]::IsNullOrWhiteSpace($c)) { break }
      $parts += $c
    }
    if ($parts.Count -eq 0) { Fail 'S00-secrets' 'no session bundle env' }
    $b64 = $parts -join ''
  }
  Test-Result 'S00-secrets' 'PASS' 'key + bundle present'
  $root = Join-Path (Temp-Base) ("snape2e-$PID")
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  try {
    $zip = Join-Path $root 'bundle.zip'
    try { [System.IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($b64)) }
    catch { Fail 'S01-bundle' 'base64 invalid' }
    $b64 = $null
    $sdir = Join-Path $root 'session'
    New-Item -ItemType Directory -Path $sdir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
      foreach ($e in $z.Entries) {
        $n = ($e.FullName -replace '/', '\')
        if ($n -match '(^|\\)\.\.(\\|$)' -or [System.IO.Path]::IsPathRooted($n) -or ($n -match '^[A-Za-z]:')) { Fail 'S01-bundle' 'traversal check' }
      }
    } finally { $z.Dispose() }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $sdir)
    Remove-Item -LiteralPath $zip -Force
    $allowed = @('telegram.session', 'telegram.session-wal', 'telegram.session-shm', 'config.json')
    $found = @{}
    Get-ChildItem -LiteralPath $sdir -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
      if (($_.Name -in $allowed) -and (-not $found.ContainsKey($_.Name))) { $found[$_.Name] = $_.FullName }
    }
    $flat = Join-Path $root 'flatsession'
    New-Item -ItemType Directory -Path $flat -Force | Out-Null
    foreach ($leaf in $allowed) { if ($found.ContainsKey($leaf)) { Copy-Item -LiteralPath $found[$leaf] -Destination (Join-Path $flat $leaf) -Force } }
    if (-not ((Test-Path (Join-Path $flat 'telegram.session')) -and (Test-Path (Join-Path $flat 'config.json')))) { Fail 'S01-bundle' 'missing session/config' }
    Test-Result 'S01-bundle' 'PASS' 'session staged'

    $env:TG_SESSION_DIR = $flat
    $res = Join-Path $root 'session.result'
    $exe = (Get-Command powershell -ErrorAction SilentlyContinue)
    if (-not $exe) { $exe = (Get-Command pwsh -ErrorAction SilentlyContinue) }
    $p = Start-Process -FilePath $exe.Source -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Here 'Enable-TelegramRest.ps1'), '-ResultFile', $res) -NoNewWindow -PassThru
    $done = $false
    try { Wait-Process -Id $p.Id -Timeout 600 -ErrorAction Stop; $done = $true } catch {}
    if (-not $done) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}; Fail 'S02-signed-in' 'Enable hung' }
    $state = ''; if (Test-Path -LiteralPath $res) { $state = (Get-Content -LiteralPath $res -Raw).Trim() }
    if (-not ($state -eq 'SIGNED-IN')) { Fail 'S02-signed-in' "session=[$state]" }
    Test-Result 'S02-signed-in' 'PASS' 'Telegram authenticated'

    $rid = $env:GITHUB_RUN_ID; if (-not $rid) { $rid = "local-$PID" }
    $work = Join-Path $root 'work'
    New-Item -ItemType Directory -Path (Join-Path $work 'sub') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $work 'marker.txt') -Value "SNAP-E2E $rid" -NoNewline
    Set-Content -LiteralPath (Join-Path $work 'sub\data.txt') -Value "payload $rid" -NoNewline
    $fakeH = Join-Path $root 'home'
    New-Item -ItemType Directory -Path $fakeH -Force | Out-Null
    . (Join-Path $Here 'Storage-Backend.ps1')
    $be0 = New-StorageBackend -Type TelegramRest -ApiKey $env:TG_API_KEY
    $before = ''
    try {
      $lj0 = Join-Path $root 'latest0.json'
      Storage-DownloadFile $be0 'envsnap/latest.json' $lj0 | Out-Null
      $before = (Get-Content $lj0 -Raw | ConvertFrom-Json).snapshot_id
    } catch {}

    $pp = Start-Process -FilePath $exe.Source -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Here 'Publish-EnvSnapshot.ps1'), '-BackendType', 'TelegramRest', '-WorkDir', $work, '-HomeRoot', $fakeH) -NoNewWindow -PassThru
    $pdone = $false
    try { Wait-Process -Id $pp.Id -Timeout 900 -ErrorAction Stop; $pdone = $true } catch {}
    if (-not $pdone) { try { Stop-Process -Id $pp.Id -Force -ErrorAction SilentlyContinue } catch {}; Fail 'S03-publish' 'publish hung' }
    # No ExitCode gate (unreadable on this host): S04's independent verify plus
    # the staleness guard below are the real proof. A failed publish leaves the
    # pointer untouched, so an unchanged latest honestly fails S04.
    Test-Result 'S03-publish' 'PASS' 'publish step finished (verified next)'

    . (Join-Path $Here 'Storage-Backend.ps1')
    $be = New-StorageBackend -Type TelegramRest -ApiKey $env:TG_API_KEY
    $lj = Join-Path $root 'latest.json'
    Storage-DownloadFile $be 'envsnap/latest.json' $lj | Out-Null
    $sid = (Get-Content $lj -Raw | ConvertFrom-Json).snapshot_id
    if (-not $sid) { Fail 'S04-verify' 'no snapshot id in latest' }
    if ($before -and ($sid -eq $before)) { Fail 'S04-verify' 'latest pointer unchanged (publish failed silently)' }
    Write-Output "SNAPSHOT|$sid"
    $mj = Join-Path $root 'snap.manifest.json'
    Storage-DownloadFile $be "envsnap/$sid.manifest.json" $mj | Out-Null
    $man = Get-Content $mj -Raw | ConvertFrom-Json
    $pz = Join-Path $root 'snap.zip'
    Storage-DownloadFile $be "envsnap/$sid.zip" $pz | Out-Null
    $st = Join-Path $root 'state'
    Expand-Archive -LiteralPath $pz -DestinationPath $st -Force
    $vbase = (Get-Item -LiteralPath $st).FullName
    $vlines = Get-ChildItem -LiteralPath $st -Recurse -File |
      Where-Object { $_.Name -ne 'manifest.json' } | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($vbase.Length) + '=' + (Get-Sha256File $_.FullName)
      }
    $vsha = (([System.Security.Cryptography.SHA256]::Create().ComputeHash(
      [System.Text.Encoding]::UTF8.GetBytes(($vlines -join "`n")))) | ForEach-Object { $_.ToString('x2') }) -join ''
    if ($vsha -ne $man.sha256) { Fail 'S04-verify' 'independent digest mismatch' }
    Test-Result 'S04-verify' 'PASS' "snapshot $sid independently verified"
  } finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  }
} catch {
  if ($_.Exception.Message -notmatch '^\[S\d\d') { Test-Result 'S99-unexpected' 'FAIL' $_.Exception.Message }
}
Write-Output "TEST|SUMMARY|PASS=$script:pass|FAIL=$script:fail|SKIP=0"
if ($script:fail -gt 0) { exit 1 }
exit 0
