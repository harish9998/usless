#Requires -Version 5.1
# Test-TelegramE2E.ps1 - decisive Telegram persistence transaction (synthetic only).
# Needs (process env, set by YOU in Actions secrets, never pasted anywhere):
#   TG_API_KEY        REST key for the DEDICATED backup account (personal only
#                     for this interim test; rotate afterwards).
#   TG_SESSION_B64    base64 session zip, or chunked TG_SESSION_B64_1..N.
# Does: decode bundle -> Enable-TelegramRest (requires SIGNED-IN) -> upload a
#   1 KB synthetic file under envsys-e2e/<run>/ -> list -> download ->
#   byte-compare + size check -> delete -> verify gone. Nothing else in the
#   drive is touched; test objects are removed even on failure.
# Exit 0 = full transaction proven. Exit 1 = anything failed (honest FAIL lines).
# Bodies, keys, and session contents are never printed.
param([string]$Namespace = '')
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source this file: execute it.' }
$Here = $PSScriptRoot
$script:pass = 0; $script:fail = 0
function Test-Result {
  param([string]$Name, [string]$Status, [string]$Detail = '')
  Write-Output "TEST|NAME=$Name|STATUS=$Status|DETAIL=$Detail"
  if ($Status -eq 'PASS') { $script:pass++ } else { $script:fail++ }
}
function Temp-Base { $t = $env:TEMP; if (-not $t) { $t = $env:TMPDIR }; if (-not $t) { $t = '/tmp' }; return $t }
function Fail([string]$n, [string]$d) { Test-Result $n 'FAIL' $d; throw "[${n}] $d" }

try {
  if ([string]::IsNullOrWhiteSpace($env:TG_API_KEY)) { Fail 'E00-secrets-present' 'TG_API_KEY env empty (set secrets first)' }
  $b64 = $env:TG_SESSION_B64
  if ([string]::IsNullOrWhiteSpace($b64)) {
    $parts = @()
    for ($k = 1; $k -le 9; $k++) {
      $c = [Environment]::GetEnvironmentVariable("TG_SESSION_B64_$k")
      if ([string]::IsNullOrWhiteSpace($c)) { break }
      $parts += $c
    }
    if ($parts.Count -eq 0) { Fail 'E00-secrets-present' 'no TG_SESSION_B64[_N] env (set secrets first)' }
    $b64 = $parts -join ''
  }
  Test-Result 'E00-secrets-present' 'PASS' 'key + bundle present (lengths hidden)'

  $root = Join-Path (Temp-Base) ("tge2e-$PID")
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  try {
    $zip = Join-Path $root 'bundle.zip'
    try { [System.IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($b64)) }
    catch { Fail 'E01-bundle-decode' 'base64 invalid' }
    $b64 = $null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
      foreach ($e in $z.Entries) {
        $n = ($e.FullName -replace '/', '\')
        if ($n -match '(^|\\)\.\.(\\|$)' -or [System.IO.Path]::IsPathRooted($n) -or ($n -match '^[A-Za-z]:')) {
          Fail 'E01-bundle-decode' 'bundle failed traversal check'
        }
      }
    } finally { $z.Dispose() }
    $sdir = Join-Path $root 'session'
    New-Item -ItemType Directory -Path $sdir -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $sdir)
    Remove-Item -LiteralPath $zip -Force
    # Required files may sit in a subfolder (zip structure varies); find them
    # by name and stage ONLY allowlisted leaves at the session root.
    $found = @{}
    Get-ChildItem -LiteralPath $sdir -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
      if (($_.Name -in $allowed) -and (-not $found.ContainsKey($_.Name))) { $found[$_.Name] = $_.FullName }
    }
    foreach ($leaf in $allowed) {
      if ($found.ContainsKey($leaf)) { Copy-Item -LiteralPath $found[$leaf] -Destination (Join-Path $sdir $leaf) -Force }
    }
    $haveSession = Test-Path -LiteralPath (Join-Path $sdir 'telegram.session')
    $haveCfg = Test-Path -LiteralPath (Join-Path $sdir 'config.json')
    if (-not ($haveSession -and $haveCfg)) { Fail 'E01-bundle-decode' 'bundle lacks telegram.session and/or config.json' }
    Test-Result 'E01-bundle-decode' 'PASS' 'bundle extracted, required files present'

    $env:TG_SESSION_DIR = $sdir
    # Stream the child live (no output redirect: buffering hides hang locations).
    # Session verdict travels via ResultFile; Wait-Process bounds the child.
    $res = Join-Path $root 'session.result'
    $flat = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Here 'Enable-TelegramRest.ps1'), '-ResultFile', $res)
    $exe = (Get-Command powershell -ErrorAction SilentlyContinue)
    if (-not $exe) { $exe = (Get-Command pwsh -ErrorAction SilentlyContinue) }
    $p = Start-Process -FilePath $exe.Source -ArgumentList $flat -NoNewWindow -PassThru
    $done = $false
    try { Wait-Process -Id $p.Id -Timeout 600 -ErrorAction Stop; $done = $true } catch {}
    if (-not $done) {
      try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
      Fail 'E02-session-signed-in' 'Enable child hung >600s (killed)'
    }
    $state = ''; $statedetail = ''
    if (Test-Path -LiteralPath $res) {
      $rawres = (Get-Content -LiteralPath $res -Raw).Trim()
      $ix = $rawres.IndexOf('|')
      if ($ix -ge 0) { $state = $rawres.Substring(0, $ix); $statedetail = $rawres.Substring($ix + 1) }
      else { $state = $rawres }
    }
    # NOTE: $p.ExitCode reads back empty on this host even after orderly child
    # exit (observed twice), so the gate is done+ResultFile, not exit code.
    # 'SIGNED-IN' is written only on the child's success path, immediately
    # before its final exit, with no blocking calls between: done + SIGNED-IN
    # proves the child completed successfully. Exit code kept for info only.
    $code = ''
    try { $p.Refresh(); $code = [string]$p.ExitCode } catch {}
    if ($done -and ($state -eq 'SIGNED-IN')) {
      Test-Result 'E02-session-signed-in' 'PASS' 'REST up, Telegram authenticated'
    } else { Fail 'E02-session-signed-in' "done=$done exit=[$code] session=[$state] $statedetail (want SIGNED-IN)" }

    . (Join-Path $Here 'Storage-Backend.ps1')
    $be = New-StorageBackend -Type TelegramRest -ApiKey $env:TG_API_KEY
    if (-not $Namespace) {
      $rid = $env:GITHUB_RUN_ID; if (-not $rid) { $rid = "local-$PID" }
      $Namespace = "envsys-e2e/$rid"
    }
    $remote = "$Namespace/payload.txt"
    $payload = ('SYNTHETIC-E2E ' + $Namespace + ' ' + (Get-Date).ToUniversalTime().ToString('o')) * 8
    $local = Join-Path $root 'payload.txt'
    Set-Content -LiteralPath $local -Value $payload -Encoding ascii -NoNewline
    $want = (Get-Item -LiteralPath $local).Length
    try {
      Storage-UploadFile $be $local $remote | Out-Null
      $sz = Storage-FileSize $be $remote
      if ($sz -ne $want) { Fail 'E03-upload-size' "size $sz vs $want" }
      Test-Result 'E03-upload-size' 'PASS' "uploaded $want bytes, size verified"
      $found = @(Storage-List $be "$Namespace/" | Where-Object { $_.name -eq $remote })
      if ($found.Count -ne 1) { Fail 'E04-list' 'uploaded object not listed' }
      Test-Result 'E04-list' 'PASS' 'listed under test namespace'
      $dl = Join-Path $root 'back.txt'
      Storage-DownloadFile $be $remote $dl | Out-Null
      $same = ((Get-Content -LiteralPath $local -Raw) -eq (Get-Content -LiteralPath $dl -Raw))
      if (-not $same) { Fail 'E05-download-bytes' 'byte mismatch' }
      Test-Result 'E05-download-bytes' 'PASS' 'byte-identical download'
    } finally {
      try { Storage-Delete $be $remote | Out-Null } catch {}
    }
    if ((Storage-FileSize $be $remote) -ne -1) { Fail 'E06-cleanup' 'test object survived delete' }
    Test-Result 'E06-cleanup' 'PASS' 'test object removed, drive untouched otherwise'
  } finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  }
} catch {
  if ($_.Exception.Message -notmatch '^\[E\d\d') { Test-Result 'E99-unexpected' 'FAIL' $_.Exception.Message }
}
Write-Output "TEST|SUMMARY|PASS=$script:pass|FAIL=$script:fail|SKIP=0"
if ($script:fail -gt 0) { exit 1 }
exit 0
