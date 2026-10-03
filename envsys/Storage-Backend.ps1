#Requires -Version 5.1
# Storage-Backend.ps1 - persistence provider abstraction. Dot-source this file, then use:
#   $be = New-StorageBackend -Type LocalDir -Root 'D:\envstore'
#   $be = New-StorageBackend -Type TelegramRest -ApiKey $env:TG_API_KEY [-BaseUrl http://localhost:8550/api/v1]
# Operations (machine-readable stdout, nonzero exit on failure, retries built in):
#   Storage-UploadFile $be <local> <remoteName> ; Storage-DownloadFile $be <remote> <local>
#   Storage-List $be [prefix] ; Storage-Delete $be <remote> ; Storage-FileSize $be <remote>
# Backends: LocalDir (filesystem dir; fully testable) and TelegramRest (Telegram Drive
# desktop app REST API; requires app running + signed in + API key).
# Telegram limits honored: 2GB/file (we split at 1.5GB), no directories (we upload
# archives), eventual listing (we retry + verify by size after upload).
$ErrorActionPreference = 'Stop'

function New-StorageBackend {
  param([ValidateSet('LocalDir','TelegramRest')][string]$Type, [string]$Root = '', [string]$ApiKey = '', [string]$BaseUrl = 'http://localhost:8550/api/v1')
  if ($Type -eq 'LocalDir') {
    if (-not $Root) { throw 'LocalDir needs -Root.' }
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    return @{ Type = 'LocalDir'; Root = $Root }
  }
  if (-not $ApiKey) { throw 'TelegramRest needs -ApiKey (pass via $env:TG_API_KEY, never a file).' }
  return @{ Type = 'TelegramRest'; ApiKey = $ApiKey; BaseUrl = $BaseUrl.TrimEnd('/') }
}

function Invoke-Curl {
  # Deterministic curl: native stderr/exit codes never rely on $ErrorActionPreference.
  # Exit 22 (HTTP error): probe the status code; 5xx/429/408 are transient (retry),
  # other 4xx fail immediately (no retry storm against auth/permissions).
  # Start-Process joins ArgumentList with spaces, so quote every arg containing spaces
  # (headers, file paths like C:\Work\Test Project\...) or curl misparses them as URLs.
  param([string[]]$CurlArgs, [string]$What = 'curl', [string]$ProbeUrl = '')
  $flat = @($CurlArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
  $err = Join-Path $env:TEMP ("curlerr-" + [guid]::NewGuid() + ".txt")
  $p = Start-Process -FilePath 'curl.exe' -ArgumentList $flat -NoNewWindow -Wait -PassThru -RedirectStandardError $err
  $msg = ''
  if (Test-Path -LiteralPath $err) { $msg = (Get-Content -LiteralPath $err -Raw); Remove-Item $err -Force -ErrorAction SilentlyContinue }
  if ($p.ExitCode -ne 0) {
    if ($p.ExitCode -eq 22 -and $ProbeUrl) {
      $code = ''
      try {
        $cout = Join-Path $env:TEMP ("curlcode-" + [guid]::NewGuid() + ".txt")
        $cerr = $cout + '.err'
        $pp = Start-Process -FilePath 'curl.exe' -ArgumentList @('-s','-o','NUL','-m','15','-w','%{http_code}',$ProbeUrl) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $cout -RedirectStandardError $cerr
        if (Test-Path -LiteralPath $cout) { $code = (Get-Content -LiteralPath $cout -Raw).Trim() }
        Remove-Item $cout, $cerr -Force -ErrorAction SilentlyContinue
      } catch {}
      if ($code -match '^(5\d\d|429|408)$') { throw "RETRYABLE $What (HTTP $code): $($msg.Trim())" }
      throw "$What HTTP error (no retry): $($msg.Trim())"
    }
    throw "$What failed (exit $($p.ExitCode)): $($msg.Trim())"
  }
}

function Storage-Root([string]$Root) {
  # Filesystem enumeration may return long or 8.3-short forms independent of how
  # we built the path. Normalize through the provider so Join/SubString agree.
  return (Get-Item -LiteralPath $Root).FullName
}

function Invoke-WithRetry {
  param([scriptblock]$Op, [int]$Tries = 4, [string]$What = 'op', [string]$Retryable = '.*')
  $delay = 2
  for ($i = 1; $i -le $Tries; $i++) {
    try { return & $Op } catch {
      $msg = $_.Exception.Message
      # Non-retryable (auth, not-found, bad request): fail immediately, do not storm.
      if (($msg -notmatch $Retryable) -or ($i -eq $Tries)) {
        if ($i -eq $Tries) { throw "FAILED $What after $Tries tries: $msg" }
        throw "NON-RETRYABLE ${What}: $msg"
      }
      Write-Warning "RETRY $What ($i/$Tries): $msg"
      Start-Sleep -Seconds $delay; $delay = $delay * 2
    }
  }
}
$CurlRetryable = 'RETRYABLE|exit (6|7|28|35|52|56)\b|429|FLOOD_WAIT|timed out|reset by peer|Could not resolve|Could not connect'

function Storage-UploadFile {
  param($Backend, [string]$Local, [string]$Remote)
  if (-not (Test-Path -LiteralPath $Local)) { throw "Upload source missing: $Local" }
  if ($Backend.Type -eq 'LocalDir') {
    $dst = Join-Path (Storage-Root $Backend.Root) $Remote
    New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
    Copy-Item -LiteralPath $Local -Destination $dst -Force
    Write-Output "STORAGE|OP=UPLOAD|REMOTE=$Remote|STATUS=SUCCESS"
    return
  }
  Invoke-WithRetry -Retryable $CurlRetryable -What "upload $Remote" -Op {
    $tmp = "$env:TEMP\tgup-$([guid]::NewGuid()).json"
    Invoke-Curl -CurlArgs @('-sS','--fail-with-body','-m','600','-H',("X-API-Key: " + $Backend.ApiKey),
      '-F',("file=@" + $Local + ";filename=" + $Remote),
      ($Backend.BaseUrl + '/files'),'-o',$tmp) -What "upload $Remote" -ProbeUrl ($Backend.BaseUrl + '/files')
    $resp = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    $size = Storage-FileSize $Backend $Remote
    $want = (Get-Item -LiteralPath $Local).Length
    if ($size -ne $want) { throw "size mismatch after upload ($size vs $want)" }
    Write-Output "STORAGE|OP=UPLOAD|REMOTE=$Remote|STATUS=SUCCESS"
  } | Write-Output
}

function Storage-FileSize {
  param($Backend, [string]$Remote)
  if ($Backend.Type -eq 'LocalDir') {
    $p = Join-Path (Storage-Root $Backend.Root) $Remote
    if (-not (Test-Path -LiteralPath $p)) { return -1 }
    return (Get-Item -LiteralPath $p).Length
  }
  $found = Storage-List $Backend $Remote | Where-Object { $_.name -eq $Remote }
  if (-not $found) { return -1 }
  return [long]$found[0].size
}

function Storage-List {
  param($Backend, [string]$Prefix = '')
  if ($Backend.Type -eq 'LocalDir') {
    return Get-ChildItem -LiteralPath (Storage-Root $Backend.Root) -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
      # Normalize to forward slashes so prefix filters behave identically on every backend.
      $rel = ($_.FullName.Substring((Storage-Root $Backend.Root).Length).TrimStart('\','/') -replace '\\','/')
      if ((-not $Prefix) -or ($rel -like "$Prefix*")) {
        [pscustomobject]@{ name = $rel; size = $_.Length; id = $rel }
      }
    }
  }
  $out = Invoke-WithRetry -Retryable $CurlRetryable -What "list $Prefix" -Op {
    $u = $Backend.BaseUrl + '/files?limit=100'
    if ($Prefix) { $u += '&search=' + [uri]::EscapeDataString($Prefix) }
    $cap = "$env:TEMP\tgls-$([guid]::NewGuid()).json"
    Invoke-Curl -CurlArgs @('-sS','--fail-with-body','-m','60','-H',("X-API-Key: " + $Backend.ApiKey),$u,'-o',$cap) -What "list $Prefix" -ProbeUrl $u
    $t = Get-Content -LiteralPath $cap -Raw; Remove-Item $cap -Force -ErrorAction SilentlyContinue
    if (-not $t) { throw "list $Prefix returned empty response" }
    $t
  }
  $j = $out | ConvertFrom-Json
  $arr = $j.files; if (-not $arr) { $arr = $j.data }
  return @($arr | ForEach-Object { [pscustomobject]@{ name = $_.name; size = $_.size; id = $_.id } })
}

function Storage-DownloadFile {
  param($Backend, [string]$Remote, [string]$Local)
  New-Item -ItemType Directory -Path (Split-Path -Parent $Local) -Force | Out-Null
  if ($Backend.Type -eq 'LocalDir') {
    $p = Join-Path (Storage-Root $Backend.Root) $Remote
    if (-not (Test-Path -LiteralPath $p)) { throw "Remote missing: $Remote" }
    Copy-Item -LiteralPath $p -Destination $Local -Force
    Write-Output "STORAGE|OP=DOWNLOAD|REMOTE=$Remote|STATUS=SUCCESS"
    return
  }
  Invoke-WithRetry -Retryable $CurlRetryable -What "download $Remote" -Op {
    $id = (Storage-List $Backend $Remote | Where-Object { $_.name -eq $Remote } | Select-Object -First 1).id
    if (-not $id) { throw "Remote missing: $Remote" }
    Invoke-Curl -CurlArgs @('-sS','--fail-with-body','-m','600','-H',("X-API-Key: " + $Backend.ApiKey),
      ($Backend.BaseUrl + "/files/$id/download"),'-o',$Local) -What "download $Remote" -ProbeUrl ($Backend.BaseUrl + "/files/$id/download")
    $tmp = "$Local.td-sync-tmp"
    Move-Item -LiteralPath $Local -Destination $tmp -Force
    Move-Item -LiteralPath $tmp -Destination $Local -Force
    Write-Output "STORAGE|OP=DOWNLOAD|REMOTE=$Remote|STATUS=SUCCESS"
  } | Write-Output
}

function Storage-Delete {
  param($Backend, [string]$Remote)
  if ($Backend.Type -eq 'LocalDir') {
    Remove-Item -LiteralPath (Join-Path (Storage-Root $Backend.Root) $Remote) -Force -ErrorAction SilentlyContinue
    Write-Output "STORAGE|OP=DELETE|REMOTE=$Remote|STATUS=SUCCESS"
    return
  }
  Invoke-WithRetry -Retryable $CurlRetryable -What "delete $Remote" -Op {
    $id = (Storage-List $Backend $Remote | Where-Object { $_.name -eq $Remote } | Select-Object -First 1).id
    if (-not $id) { Write-Output "STORAGE|OP=DELETE|REMOTE=$Remote|STATUS=SKIP-MISSING"; return }
    Invoke-Curl -CurlArgs @('-sS','--fail-with-body','-m','60','-X','DELETE','-H',("X-API-Key: " + $Backend.ApiKey),
      ($Backend.BaseUrl + "/files/$id")) -What "delete $Remote" -ProbeUrl ($Backend.BaseUrl + "/files/$id")
    Write-Output "STORAGE|OP=DELETE|REMOTE=$Remote|STATUS=SUCCESS"
  } | Write-Output
}
