#Requires -Version 5.1
# Test-RestoreE2E.ps1 - Runner B side: restore Runner A's snapshot on a FRESH
# runner through the REAL Telegram backend, verify content, clean the store.
# Env: TG_API_KEY (required), TG_SESSION_B64[_N] (required).
# Flow: bundle -> Enable (SIGNED-IN) -> read latest.json -> independent digest
# verify -> Invoke-EnvBootstrap (TelegramRest) into a clean dir -> marker files
# present with SNAP-E2E contents -> delete test snapshot + latest pointer.
# Exit 0 = restored, verified, cleaned. Exit 1 = anything failed.
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
  if ([string]::IsNullOrWhiteSpace($env:TG_API_KEY)) { Fail 'R00-secrets' 'TG_API_KEY empty' }
  $b64 = $env:TG_SESSION_B64
  if ([string]::IsNullOrWhiteSpace($b64)) {
    $parts = @()
    for ($k = 1; $k -le 9; $k++) {
      $c = [Environment]::GetEnvironmentVariable("TG_SESSION_B64_$k")
      if ([string]::IsNullOrWhiteSpace($c)) { break }
      $parts += $c
    }
    if ($parts.Count -eq 0) { Fail 'R00-secrets' 'no session bundle env' }
    $b64 = $parts -join ''
  }
  Test-Result 'R00-secrets' 'PASS' 'key + bundle present'
  $root = Join-Path (Temp-Base) ("rste2e-$PID")
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  try {
    $zip = Join-Path $root 'bundle.zip'
    try { [System.IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($b64)) }
    catch { Fail 'R01-bundle' 'base64 invalid' }
    $b64 = $null
    $sdir = Join-Path $root 'session'
    New-Item -ItemType Directory -Path $sdir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
      foreach ($e in $z.Entries) {
        $n = ($e.FullName -replace '/', '\')
        if ($n -match '(^|\\)\.\.(\\|$)' -or [System.IO.Path]::IsPathRooted($n) -or ($n -match '^[A-Za-z]:')) { Fail 'R01-bundle' 'traversal check' }
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
    if (-not ((Test-Path (Join-Path $flat 'telegram.session')) -and (Test-Path (Join-Path $flat 'config.json')))) { Fail 'R01-bundle' 'missing session/config' }
    Test-Result 'R01-bundle' 'PASS' 'session staged'

    $env:TG_SESSION_DIR = $flat
    $res = Join-Path $root 'session.result'
    $exe = (Get-Command powershell -ErrorAction SilentlyContinue)
    if (-not $exe) { $exe = (Get-Command pwsh -ErrorAction SilentlyContinue) }
    $p = Start-Process -FilePath $exe.Source -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Here 'Enable-TelegramRest.ps1'), '-ResultFile', $res) -NoNewWindow -PassThru
    $done = $false
    try { Wait-Process -Id $p.Id -Timeout 600 -ErrorAction Stop; $done = $true } catch {}
    if (-not $done) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}; Fail 'R02-signed-in' 'Enable hung' }
    $state = ''; $statedetail = ''
    if (Test-Path -LiteralPath $res) {
      $rawres = (Get-Content -LiteralPath $res -Raw).Trim()
      $ix = $rawres.IndexOf('|')
      if ($ix -ge 0) { $state = $rawres.Substring(0, $ix); $statedetail = $rawres.Substring($ix + 1) }
      else { $state = $rawres }
    }
    if (-not ($state -eq 'SIGNED-IN')) { Fail 'R02-signed-in' "session=[$state] $statedetail" }
    Test-Result 'R02-signed-in' 'PASS' 'Telegram authenticated'

    . (Join-Path $Here 'Storage-Backend.ps1')
    $be = New-StorageBackend -Type TelegramRest -ApiKey $env:TG_API_KEY
    $lj = Join-Path $root 'latest.json'
    try { Storage-DownloadFile $be 'envsnap/latest.json' $lj | Out-Null }
    catch { Fail 'R03-fetch' 'no latest snapshot (Runner A never published?)' }
    $sid = (Get-Content $lj -Raw | ConvertFrom-Json).snapshot_id
    if (-not $sid) { Fail 'R03-fetch' 'empty snapshot id' }
    Write-Output "RESTORE-SOURCE|$sid"
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
    if ($vsha -ne $man.sha256) { Fail 'R03-fetch' 'store digest mismatch (corrupt in flight?)' }
    Test-Result 'R03-fetch' 'PASS' "snapshot $sid verified from store"

    $rst = Join-Path $root 'restored'
    $fakeH = Join-Path $root 'home'
    $bp = Start-Process -FilePath $exe.Source -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Here 'Invoke-EnvBootstrap.ps1'), '-BackendType', 'TelegramRest', '-WorkDir', $rst, '-HomeRoot', $fakeH) -NoNewWindow -PassThru
    $bdone = $false
    try { Wait-Process -Id $bp.Id -Timeout 900 -ErrorAction Stop; $bdone = $true } catch {}
    if (-not $bdone) { try { Stop-Process -Id $bp.Id -Force -ErrorAction SilentlyContinue } catch {}; Fail 'R04-restore' 'bootstrap hung' }
    $mk = Join-Path $rst 'marker.txt'
    $mkOk = ((Test-Path -LiteralPath $mk) -and ((Get-Content -LiteralPath $mk -Raw) -match '^SNAP-E2E '))
    $dtOk = ((Test-Path -LiteralPath (Join-Path $rst 'sub\data.txt')))
    if (-not ($mkOk -and $dtOk)) { Fail 'R04-restore' 'Runner A files missing after bootstrap' }
    Test-Result 'R04-restore' 'PASS' 'Runner A state restored on Runner B'

    $delNames = @("envsnap/$sid.zip", "envsnap/$sid.manifest.json", 'envsnap/latest.json')
    foreach ($obj in $delNames) {
      try { Storage-Delete $be $obj | Out-Null } catch {}
    }
    # Deletes can be eventually consistent: poll before declaring failure.
    $left = @()
    for ($k = 1; $k -le 6; $k++) {
      Start-Sleep -Seconds 20
      $left = @(Storage-List $be 'envsnap/' | Where-Object {
        $_.name -like '*envsnap-*.zip' -or $_.name -like '*.manifest.json' -or $_.name -like '*latest.json' })
      if ($left.Count -eq 0) { break }
    }
    if ($left.Count -gt 0) {
      Fail 'R05-cleanup' ("store not clean: " + (($left | ForEach-Object { $_.name }) -join ','))
    }
    Test-Result 'R05-cleanup' 'PASS' 'test snapshot removed from store'
  } finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  }
} catch {
  if ($_.Exception.Message -notmatch '^\[[SR]\d\d') { Test-Result 'R99-unexpected' 'FAIL' $_.Exception.Message }
}
Write-Output "TEST|SUMMARY|PASS=$script:pass|FAIL=$script:fail|SKIP=0"
if ($script:fail -gt 0) { exit 1 }
exit 0
