#Requires -Version 5.1
# Test-EnvSystem.ps1 - LocalDir regression harness for the envsys persistence chain.
# Zero secrets, no network. Portable checks run on any host (Windows PowerShell 5.1
# and PowerShell 7); the full publish -> restore -> corrupt -> fallback chain needs
# Windows (robocopy/registry/schtasks) and reports SKIP elsewhere. Skips are never
# counted as passes.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File Test-EnvSystem.ps1 [-StoreRoot D:\envstore-test] [-FailOnSkip]
#
# Machine-readable stdout: TEST|NAME=<id>|STATUS=PASS|FAIL|SKIP|DETAIL=<text>
# Exit 0 = no FAIL (skips allowed unless -FailOnSkip). Exit 1 = any FAIL.
# All secret-like values below are synthetic and clearly fake.
param([string]$StoreRoot = '', [string]$RepoRoot = '', [switch]$FailOnSkip)
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source this file: execute it.' }

$Here = $PSScriptRoot
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $Here }
$script:pass = 0; $script:fail = 0; $script:skip = 0
function Test-Result {
  param([string]$Name, [string]$Status, [string]$Detail = '')
  Write-Output "TEST|NAME=$Name|STATUS=$Status|DETAIL=$Detail"
  switch ($Status) { 'PASS' { $script:pass++ } 'FAIL' { $script:fail++ } default { $script:skip++ } }
}
function Temp-Base {
  $t = $env:TEMP; if (-not $t) { $t = $env:TMPDIR }; if (-not $t) { $t = '/tmp' }; return $t
}
function New-TestDir([string]$name) {
  $p = Join-Path (Temp-Base) ("envtest-$PID-$name")
  if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force }
  New-Item -ItemType Directory -Path $p -Force | Out-Null
  return (Get-Item -LiteralPath $p).FullName
}
$IsWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
$HaveRobocopy = [bool](Get-Command robocopy -ErrorAction SilentlyContinue)
$WinChain = ($IsWin -and $HaveRobocopy)
$PsExe = (Get-Command powershell -ErrorAction SilentlyContinue)
if (-not $PsExe) { $PsExe = (Get-Command pwsh -ErrorAction SilentlyContinue) }
$PsExe = $PsExe.Source
function Invoke-Child {
  # Runs a sibling script out-of-process and returns its exit code (honest gating).
  param([string]$Script, [string[]]$Extra = @(), [string]$CaptureOut = '')
  $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Extra
  $flat = @($args | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
  if ($CaptureOut) {
    $p = Start-Process -FilePath $PsExe -ArgumentList $flat -NoNewWindow -Wait -PassThru -RedirectStandardOutput $CaptureOut
  } else {
    $p = Start-Process -FilePath $PsExe -ArgumentList $flat -NoNewWindow -Wait -PassThru
  }
  return $p.ExitCode
}
function Get-Sha256Text([string]$t) {
  $b = [System.Text.Encoding]::UTF8.GetBytes($t)
  return (([System.Security.Cryptography.SHA256]::Create().ComputeHash($b) | ForEach-Object { $_.ToString('x2') }) -join '')
}

$FakePat = 'ghp_FAKEFAKEFAKEFAKEFAKE12'
$FakeKey = '-----BEGIN RSA PRIVATE KEY-----'

# ---------- Portable: secret gate ----------
try {
  $d = New-TestDir 'dirty'
  New-Item -ItemType Directory -Path (Join-Path $d 'user-config\claude') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $d 'user-config\claude\secret-pat.json') -Value ('{"api":"' + $FakePat + '"}') -NoNewline
  Set-Content -LiteralPath (Join-Path $d 'user-config\claude\id.key') -Value ($FakeKey + "`nFAKE") -NoNewline
  Set-Content -LiteralPath (Join-Path $d '.env') -Value 'FAKE=1' -NoNewline
  Set-Content -LiteralPath (Join-Path $d 'auth.json') -Value '{"tok":"x"}' -NoNewline
  Set-Content -LiteralPath (Join-Path $d 'user-config\claude\settings.json') -Value '{"theme":"dark"}' -NoNewline
  Set-Content -LiteralPath (Join-Path $d 'user-config\claude\config.json') -Value '{"mcp":"ok"}' -NoNewline
  Set-Content -LiteralPath (Join-Path $d 'user-config\claude\history.jsonl') -Value '{"h":1}' -NoNewline
  $c = Invoke-Child (Join-Path $Here 'Protect-SnapshotSecrets.ps1') @('-Path', $d)
  if ($c -eq 2) { Test-Result 'P02-secret-gate-dirty' 'PASS' '4 synthetic hits incl /.env, exit 2' }
  else { Test-Result 'P02-secret-gate-dirty' 'FAIL' "exit=$c, want 2" }
  Remove-Item -LiteralPath $d -Recurse -Force
} catch { Test-Result 'P02-secret-gate-dirty' 'FAIL' $_.Exception.Message }
try {
  $d = New-TestDir 'clean'
  New-Item -ItemType Directory -Path (Join-Path $d 'user-config\claude') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $d 'user-config\claude\settings.json') -Value '{"theme":"dark"}' -NoNewline
  Set-Content -LiteralPath (Join-Path $d 'user-config\claude\config.json') -Value '{"mcp":"ok"}' -NoNewline
  $c = Invoke-Child (Join-Path $Here 'Protect-SnapshotSecrets.ps1') @('-Path', $d)
  if ($c -eq 0) { Test-Result 'P03-secret-gate-clean' 'PASS' 'exit 0' }
  else { Test-Result 'P03-secret-gate-clean' 'FAIL' "exit=$c, want 0" }
  Remove-Item -LiteralPath $d -Recurse -Force
} catch { Test-Result 'P03-secret-gate-clean' 'FAIL' $_.Exception.Message }
try {
  $d = New-TestDir 'dot'
  Set-Content -LiteralPath (Join-Path $d '.credentials.json') -Value '{"a":1}' -NoNewline
  $c = Invoke-Child (Join-Path $Here 'Protect-SnapshotSecrets.ps1') @('-Path', $d)
  if ($c -eq 2) { Test-Result 'P04-secret-gate-dotfile' 'PASS' '.credentials.json caught, exit 2' }
  else { Test-Result 'P04-secret-gate-dotfile' 'FAIL' "exit=$c, want 2" }
  Remove-Item -LiteralPath $d -Recurse -Force
} catch { Test-Result 'P04-secret-gate-dotfile' 'FAIL' $_.Exception.Message }

# ---------- Portable: storage backend (LocalDir) ----------
try {
  . (Join-Path $Here 'Storage-Backend.ps1')
  $st = New-TestDir 'store'; $sr = New-TestDir 'src'
  Set-Content -LiteralPath (Join-Path $sr 'payload.txt') -Value 'hello storage backend' -NoNewline
  $be = New-StorageBackend -Type LocalDir -Root $st
  Storage-UploadFile $be (Join-Path $sr 'payload.txt') 'envsnap/payload.txt' | Out-Null
  $sz = Storage-FileSize $be 'envsnap/payload.txt'
  $lst = @(Storage-List $be 'envsnap/')
  Storage-DownloadFile $be 'envsnap/payload.txt' (Join-Path $sr 'restored.txt') | Out-Null
  $rt = ((Get-Content (Join-Path $sr 'payload.txt') -Raw) -eq (Get-Content (Join-Path $sr 'restored.txt') -Raw))
  Storage-Delete $be 'envsnap/payload.txt' | Out-Null
  $gone = (Storage-FileSize $be 'envsnap/payload.txt')
  if (($sz -eq 21) -and ($lst.Count -ge 1) -and $rt -and ($gone -eq -1)) {
    Test-Result 'P05-storage-roundtrip' 'PASS' 'upload/size/list/download/delete verified'
  } else { Test-Result 'P05-storage-roundtrip' 'FAIL' "sz=$sz list=$($lst.Count) rt=$rt gone=$gone" }
  try { Storage-UploadFile $be (Join-Path $sr 'nope.txt') 'envsnap/nope.txt' | Out-Null
    Test-Result 'P06-storage-missing-source' 'FAIL' 'upload of absent file did not throw'
  } catch { Test-Result 'P06-storage-missing-source' 'PASS' 'missing source throws' }
  Remove-Item -LiteralPath $st -Recurse -Force; Remove-Item -LiteralPath $sr -Recurse -Force
} catch { Test-Result 'P05-storage-roundtrip' 'FAIL' $_.Exception.Message }

# ---------- Portable: syntax + structural regression tripwires (labeled STATIC) ----------
try {
  $errs = @()
  Get-ChildItem -LiteralPath $Here -Filter '*.ps1' -Recurse | ForEach-Object {
    $tk = $null; $er = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tk, [ref]$er) | Out-Null
    if ($er.Count -gt 0) { $errs += $_.Name }
  }
  $tp = Join-Path $Here 'portable-rdp-env-toolkit'
  if (Test-Path -LiteralPath $tp) {
    Get-ChildItem -LiteralPath $tp -Filter '*.ps1' | ForEach-Object {
      $tk = $null; $er = $null
      [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tk, [ref]$er) | Out-Null
      if ($er.Count -gt 0) { $errs += $_.Name }
    }
  }
  if ($errs.Count -eq 0) { Test-Result 'P01-syntax-all' 'PASS' 'parser errors 0' }
  else { Test-Result 'P01-syntax-all' 'FAIL' ($errs -join ',') }
} catch { Test-Result 'P01-syntax-all' 'FAIL' $_.Exception.Message }
try {
  $wf = Get-Content -LiteralPath (Join-Path $RepoRoot '.github/workflows/main.yml') -Raw
  if ($wf -match '(?m)^\s*if:.*secrets\.') { Test-Result 'S02-no-secrets-in-workflow-if' 'FAIL' 'secret in if: expression' }
  else { Test-Result 'S02-no-secrets-in-workflow-if' 'PASS' 'STATIC: no secrets in if:' }
} catch { Test-Result 'S02-no-secrets-in-workflow-if' 'FAIL' $_.Exception.Message }
try {
  $g = Get-Content -LiteralPath (Join-Path $Here 'Protect-SnapshotSecrets.ps1') -Raw
  if ($g -match 'Get-ChildItem.*-Force') { Test-Result 'S03-scanner-sees-dotfiles' 'PASS' 'STATIC: -Force present' }
  else { Test-Result 'S03-scanner-sees-dotfiles' 'FAIL' 'STATIC: -Force missing, .env invisible' }
} catch { Test-Result 'S03-scanner-sees-dotfiles' 'FAIL' $_.Exception.Message }
try {
  $b = Get-Content -LiteralPath (Join-Path $Here 'Invoke-EnvBootstrap.ps1') -Raw
  if (($b -match 'Test-ZipSafe') -and ($b -match 'payload digest mismatch')) {
    Test-Result 'S04-bootstrap-verify-structure' 'PASS' 'STATIC: traversal + payload recompute present'
  } else { Test-Result 'S04-bootstrap-verify-structure' 'FAIL' 'STATIC: verify logic absent' }
} catch { Test-Result 'S04-bootstrap-verify-structure' 'FAIL' $_.Exception.Message }

# ---------- Windows-only chain (robocopy/registry/schtasks) ----------
if (-not $WinChain) {
  foreach ($n in @('W10-publish-restore-reconcile', 'W11-corrupt-fallback', 'W12-orphan-ignored',
      'W13-concurrent-publishers', 'W14-secret-publish-rejected', 'W15-prune-keeps-good')) {
    Test-Result $n 'SKIP' 'needs Windows + robocopy'
  }
} else {
  if (-not $StoreRoot) { $StoreRoot = Join-Path (Temp-Base) ("envtest-$PID-store") }
  if (Test-Path -LiteralPath $StoreRoot) { Remove-Item -LiteralPath $StoreRoot -Recurse -Force }
  New-Item -ItemType Directory -Path $StoreRoot -Force | Out-Null
  $StoreRoot = (Get-Item -LiteralPath $StoreRoot).FullName
  $Pub = New-TestDir 'pub'; $Rst = New-TestDir 'rst'; $FakeHome = New-TestDir 'home'
  $Publish = Join-Path $Here 'Publish-EnvSnapshot.ps1'
  $Bootstrap = Join-Path $Here 'Invoke-EnvBootstrap.ps1'
  function Pub-Now { Invoke-Child $Publish @('-BackendType', 'LocalDir', '-Root', $StoreRoot, '-WorkDir', $Pub, '-HomeRoot', $FakeHome) }
  function Boot-Now([string]$Out) {
    $c = Invoke-Child $Bootstrap @('-BackendType', 'LocalDir', '-Root', $StoreRoot, '-WorkDir', $Rst, '-HomeRoot', $FakeHome) -CaptureOut $Out
    $script:lastBootOut = $Out
    return $c
  }
  function Boot-Detail([string]$Out, [int]$n = 12) {
    if (Test-Path -LiteralPath $Out) {
      $lines = @(Get-Content -LiteralPath $Out | Where-Object { $_ -match 'FAIL|FAIL-|Error|error|mismatch|degraded|BAD|bad' } | Select-Object -First $n)
      if ($lines.Count -eq 0) { $lines = @(Get-Content -LiteralPath $Out | Select-Object -Last $n) }
      return ($lines -join ' / ').Substring(0, [Math]::Min(400, ($lines -join ' / ').Length))
    }
    return 'no capture'
  }
  function Store-LatestId {
    $t = Join-Path (Temp-Base) ("envtest-$PID-latest.json")
    . (Join-Path $Here 'Storage-Backend.ps1')
    $be = New-StorageBackend -Type LocalDir -Root $StoreRoot
    Storage-DownloadFile $be 'envsnap/latest.json' $t | Out-Null
    $id = (Get-Content $t -Raw | ConvertFrom-Json).snapshot_id
    Remove-Item $t -Force; return $id
  }
  try {
    # Seed generation 1: A + sub/B, plus secret-named files that must be EXCLUDED from the archive.
    New-Item -ItemType Directory -Path (Join-Path $Pub 'sub') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Pub 'A.txt') -Value 'A-v1' -NoNewline
    Set-Content -LiteralPath (Join-Path $Pub 'sub\B.txt') -Value 'B-v1' -NoNewline
    Set-Content -LiteralPath (Join-Path $Pub '.env') -Value 'SHOULD-NOT-SHIP=1' -NoNewline
    Set-Content -LiteralPath (Join-Path $Pub 'auth.json') -Value '{"tok":"x"}' -NoNewline
    if ((Pub-Now) -ne 0) { throw 'publish gen1 failed' }
    $snap1 = Store-LatestId
    # Generation 2: modify A, delete B, add D.
    Set-Content -LiteralPath (Join-Path $Pub 'A.txt') -Value 'A-v2' -NoNewline
    Remove-Item -LiteralPath (Join-Path $Pub 'sub\B.txt') -Force
    Set-Content -LiteralPath (Join-Path $Pub 'D.txt') -Value 'D-v2' -NoNewline
    if ((Pub-Now) -ne 0) { throw 'publish gen2 failed' }
    $snap2 = Store-LatestId
    if (($snap1 -eq $snap2) -or (-not $snap1) -or (-not $snap2)) { throw 'snapshot ids not unique' }
    $o = Join-Path (Temp-Base) ("envtest-$PID-boot1.txt")
    if ((Boot-Now $o) -ne 0) { throw ('bootstrap gen2 failed: ' + (Boot-Detail $o)) }
    $a = Get-Content -LiteralPath (Join-Path $Rst 'A.txt') -Raw
    $bGone = -not (Test-Path -LiteralPath (Join-Path $Rst 'sub\B.txt'))
    $dOk = ((Get-Content -LiteralPath (Join-Path $Rst 'D.txt') -Raw) -eq 'D-v2')
    $envGone = -not (Test-Path -LiteralPath (Join-Path $Rst '.env'))
    $authGone = -not (Test-Path -LiteralPath (Join-Path $Rst 'auth.json'))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $StoreRoot ("envsnap\" + $snap2 + '.zip')))
    try { $entries = @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
    $zipClean = -not ($entries -match '\.env$|auth\.json$')
    if (($a -eq 'A-v2') -and $bGone -and $dOk -and $envGone -and $authGone -and $zipClean) {
      Test-Result 'W10-publish-restore-reconcile' 'PASS' 'modify+delete+add reconciled, secrets absent in restore and archive'
    } else { Test-Result 'W10-publish-restore-reconcile' 'FAIL' "a=$a bGone=$bGone dOk=$dOk envGone=$envGone authGone=$authGone zipClean=$zipClean" }
  } catch { Test-Result 'W10-publish-restore-reconcile' 'FAIL' $_.Exception.Message }

  try {
    # Orphan/unreferenced objects must not disturb the live chain.
    Set-Content -LiteralPath (Join-Path $StoreRoot 'envsnap\envsnap-ORPHAN.zip') -Value 'garbage-not-a-snapshot' -NoNewline
    $o = Join-Path (Temp-Base) ("envtest-$PID-boot2.txt")
    if ((Boot-Now $o) -ne 0) { throw ('bootstrap with orphan present failed: ' + (Boot-Detail $o)) }
    Test-Result 'W12-orphan-ignored' 'PASS' 'unreferenced object ignored, latest restores'
  } catch { Test-Result 'W12-orphan-ignored' 'FAIL' $_.Exception.Message }

  try {
    # Corrupt ONLY the latest payload; bootstrap must reject it and fall back to previous-good.
    $zp = Join-Path $StoreRoot ("envsnap\" + $snap2 + '.zip')
    $fs = [System.IO.File]::Open($zp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite)
    try { $fs.Seek(100, [System.IO.SeekOrigin]::Begin) | Out-Null; $fs.WriteByte(0xFF) } finally { $fs.Close() }
    $o = Join-Path (Temp-Base) ("envtest-$PID-boot3.txt")
    $code = Boot-Now $o
    $txt = Get-Content -LiteralPath $o -Raw
    $fb = ($txt -match 'SUCCESS-FALLBACK')
    $a = Get-Content -LiteralPath (Join-Path $Rst 'A.txt') -Raw
    $bBack = ((Get-Content -LiteralPath (Join-Path $Rst 'sub\B.txt') -Raw) -eq 'B-v1')
    $dGone = -not (Test-Path -LiteralPath (Join-Path $Rst 'D.txt'))
    if (($code -eq 0) -and $fb -and ($a -eq 'A-v1') -and $bBack -and $dGone) {
      Test-Result 'W11-corrupt-fallback' 'PASS' 'corrupt latest rejected, previous-good restored'
    } else { Test-Result 'W11-corrupt-fallback' 'FAIL' "code=$code fallback=$fb a=$a bBack=$bBack dGone=$dGone" }
  } catch { Test-Result 'W11-corrupt-fallback' 'FAIL' $_.Exception.Message }

  try {
    # Concurrent publishers must get unique ids/staging (real parallel jobs, own PIDs).
    $j1w = New-TestDir 'job1'; $j2w = New-TestDir 'job2'
    Set-Content -LiteralPath (Join-Path $j1w 'J.txt') -Value 'job1' -NoNewline
    Set-Content -LiteralPath (Join-Path $j2w 'J.txt') -Value 'job2' -NoNewline
    $jobs = @()
    foreach ($w in @($j1w, $j2w)) {
      $jobs += Start-Job -ScriptBlock {
        param($P, $R, $W, $H)
        & powershell -NoProfile -ExecutionPolicy Bypass -File $P -BackendType LocalDir -Root $R -WorkDir $W -HomeRoot $H | Out-Null
        return $LASTEXITCODE
      } -ArgumentList $Publish, $StoreRoot, $w, $FakeHome
    }
    Wait-Job -Job $jobs -Timeout 600 | Out-Null
    $codes = @($jobs | Receive-Job); Remove-Job -Job $jobs -Force
    . (Join-Path $Here 'Storage-Backend.ps1')
    $be = New-StorageBackend -Type LocalDir -Root $StoreRoot
    $mans = @(Storage-List $be 'envsnap/envsnap-' | Where-Object { $_.name -match '\.manifest\.json$' })
    $ids = @($mans | ForEach-Object { ($_.name -replace '^.*[/\\]([^/\\]+)\.manifest\.json$', '$1') })
    $uniq = @($ids | Sort-Object -Unique)
    if (($codes -notcontains $null) -and ($codes | Where-Object { $_ -ne 0 }).Count -eq 0 -and ($uniq.Count -eq $ids.Count) -and ($ids.Count -ge 4)) {
      Test-Result 'W13-concurrent-publishers' 'PASS' "$($ids.Count) manifests, all unique, jobs exit 0"
    } else { Test-Result 'W13-concurrent-publishers' 'FAIL' "codes=$($codes -join ',') manifests=$($ids.Count) unique=$($uniq.Count)" }
  } catch { Test-Result 'W13-concurrent-publishers' 'FAIL' $_.Exception.Message }

  try {
    # Secret CONTENT in a normal file must abort publish; latest pointer must not move.
    $before = Store-LatestId
    Set-Content -LiteralPath (Join-Path $Pub 'notes.txt') -Value ("token " + $FakePat) -NoNewline
    $code = Pub-Now
    $after = Store-LatestId
    Remove-Item -LiteralPath (Join-Path $Pub 'notes.txt') -Force
    if (($code -ne 0) -and ($before -eq $after)) {
      Test-Result 'W14-secret-publish-rejected' 'PASS' 'fail-closed, latest untouched'
    } else { Test-Result 'W14-secret-publish-rejected' 'FAIL' "code=$code moved=$($before -ne $after)" }
  } catch { Test-Result 'W14-secret-publish-rejected' 'FAIL' $_.Exception.Message }

  try {
    # Retention: bounded history, latest always restorable.
    Set-Content -LiteralPath (Join-Path $Pub 'tick.txt') -Value 't1' -NoNewline
    Invoke-Child $Publish @('-BackendType', 'LocalDir', '-Root', $StoreRoot, '-WorkDir', $Pub, '-HomeRoot', $FakeHome, '-Keep', '2') | Out-Null
    Set-Content -LiteralPath (Join-Path $Pub 'tick.txt') -Value 't2' -NoNewline
    Invoke-Child $Publish @('-BackendType', 'LocalDir', '-Root', $StoreRoot, '-WorkDir', $Pub, '-HomeRoot', $FakeHome, '-Keep', '2') | Out-Null
    . (Join-Path $Here 'Storage-Backend.ps1')
    $be = New-StorageBackend -Type LocalDir -Root $StoreRoot
    $mans = @(Storage-List $be 'envsnap/envsnap-' | Where-Object { $_.name -match '\.manifest\.json$' })
    $o = Join-Path (Temp-Base) ("envtest-$PID-boot4.txt")
    $code = Boot-Now $o
    if (($mans.Count -le 3) -and ($code -eq 0)) {
      Test-Result 'W15-prune-keeps-good' 'PASS' "$($mans.Count) manifests retained, latest restores"
    } else { Test-Result 'W15-prune-keeps-good' 'FAIL' "manifests=$($mans.Count) boot=$code detail=$(Boot-Detail $o)" }
  } catch { Test-Result 'W15-prune-keeps-good' 'FAIL' $_.Exception.Message }

  Remove-Item -LiteralPath $Pub -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Rst -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $FakeHome -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $StoreRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "TEST|SUMMARY|PASS=$script:pass|FAIL=$script:fail|SKIP=$script:skip"
if ($script:fail -gt 0) { exit 1 }
if ($FailOnSkip -and ($script:skip -gt 0)) { exit 1 }
exit 0
