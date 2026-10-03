#Requires -Version 5.1
# Publish-EnvSnapshot.ps1 - capture -> scan(fail-closed) -> zip -> upload -> verify -> publish.
#   powershell -File Publish-EnvSnapshot.ps1 -BackendType LocalDir -Root D:\envstore [-WorkDir C:\Work]
#   powershell -File Publish-EnvSnapshot.ps1 -BackendType TelegramRest   # needs $env:TG_API_KEY + app running
# Never replaces latest until the new snapshot is verified. Never publishes secrets.
param([ValidateSet('LocalDir','TelegramRest')][string]$BackendType = 'LocalDir',
  [string]$Root = '', [string]$WorkDir = 'C:\Work', [string]$HomeRoot = '', [int]$Keep = 8)
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source this file: execute it. (Top-level pipeline code would run on import.)' }
function Split-Archive { param([string]$zip, [string]$stage, [string]$sid)
  # Returns @(single zip) or @(part files) for >1.5GB archives (Telegram 2GB/file cap).
  if ((Get-Item -LiteralPath $zip).Length -le 1500MB) { return @($zip) }
  $parts = @(); $i = 0; $buf = New-Object byte[] (100MB)
  $fs = [System.IO.File]::OpenRead($zip)
  try {
    while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
      $i++; $p = "$stage\$sid.part$("{0:000}" -f $i)"
      $os = [System.IO.File]::OpenWrite($p); $os.Write($buf, 0, $n); $os.Close()
      $parts += $p
    }
  } finally { $fs.Close() }
  return $parts
}
. "$PSScriptRoot\Storage-Backend.ps1"
function Get-Sha256File([string]$p) {
  $s = [System.IO.File]::OpenRead($p)
  try { ([System.Security.Cryptography.SHA256]::Create().ComputeHash($s) | ForEach-Object { $_.ToString('x2') }) -join '' }
  finally { $s.Close() }
}
function Status([string]$c, [string]$s) { Write-Output "PUBLISH|COMPONENT=$c|STATUS=$s" }
$ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
# Uniqueness across concurrent publishers: timestamp + run id (never bare timestamp).
$rid = $env:GITHUB_RUN_ID
if (-not $rid) { $rid = $env:COMPUTERNAME }
$sid = "envsnap-$ts-$rid-$PID"
# Unique staging per process: concurrent publishers must never share temp space.
$stage = Join-Path $env:TEMP "envpub-$ts-$PID"
New-Item -ItemType Directory -Path $stage -Force | Out-Null

try {
  # 1. Capture (+ workspace content staged beside state for the archive)
  Status 'Capture' 'START'
  & "$PSScriptRoot\Capture-WindowsEnvironment.ps1" -OutDir "$stage\state" -HomeRoot $HomeRoot -WorkDir $WorkDir -RunnerId "gh-runner-$env:GITHUB_RUN_ID" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'capture failed' }
  if (Test-Path -LiteralPath $WorkDir) {
    New-Item -ItemType Directory -Path "$stage\state\workspace-data" -Force | Out-Null
    & robocopy $WorkDir "$stage\state\workspace-data" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NP `
      /XF .credentials.json auth.json .env *.env *.key *token*.json credentials*.json `
      /XD Cache 'Code Cache' GPUCache Crashpad node_modules .git | Out-Null
  }
  Status 'Capture' 'SUCCESS'

  # 1b. Stage workspace CONTENT beside state (Restore expects workspace-data/; same exclusions).
  if (Test-Path -LiteralPath $WorkDir) {
    New-Item -ItemType Directory -Path "$stage\state\workspace-data" -Force | Out-Null
    & robocopy $WorkDir "$stage\state\workspace-data" /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NP `
      /XF .credentials.json auth.json .env *.env *.key *token*.json credentials*.json `
      /XD Cache 'Code Cache' GPUCache Crashpad node_modules .git | Out-Null
  }

  # 2. Secret scan (HARD FAIL - nothing uploads on failure)
  Status 'SecretsScan' 'START'
  powershell -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot\Protect-SnapshotSecrets.ps1" -Path "$stage\state"
  if ($LASTEXITCODE -ne 0) { Status 'SecretsScan' 'FAIL'; throw 'secret gate failed - snapshot rejected, nothing published' }
  Status 'SecretsScan' 'PASS'

  # 3. Manifest + zip (+ split for Telegram 2GB/file cap at 1.5GB parts)
  $files = Get-ChildItem "$stage\state" -Recurse -File
  $stbase = (Get-Item -LiteralPath "$stage\state").FullName
  $total = ($files | Measure-Object Length -Sum).Sum
  $dig = ([System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes((($files | Sort-Object FullName | ForEach-Object {
      $_.FullName.Substring($stbase.Length) + '=' + (Get-Sha256File $_.FullName)
    }) -join "`n")) ) | ForEach-Object { $_.ToString('x2') }) -join ''
  $prev = ''
  $be0args = @{ Type = $BackendType }
  if ($BackendType -eq 'LocalDir') { $be0args.Root = $Root } else { $be0args.ApiKey = $env:TG_API_KEY }
  $be = New-StorageBackend @be0args
  try {
    $tmp = Join-Path $env:TEMP "envlatest-$ts.json"
    Storage-DownloadFile $be 'envsnap/latest.json' $tmp | Out-Null
    $prev = (Get-Content $tmp -Raw | ConvertFrom-Json).snapshot_id
    Remove-Item $tmp -Force
  } catch {}
  @{ snapshot_id = $sid; created_utc = (Get-Date).ToUniversalTime().ToString('o');
     runner_id = "gh-runner-$env:GITHUB_RUN_ID"; parent_snapshot_id = $prev;
     file_count = $files.Count; total_bytes = $total; sha256 = $dig;
     schema_version = 1; tool_version = 'envsys-1'; parts = 0 } |
    ConvertTo-Json -Compress | Out-File -LiteralPath "$stage\state\manifest.json" -Encoding ascii
  Copy-Item -LiteralPath "$stage\state\manifest.json" -Destination "$stage\manifest.json" -Force
  Compress-Archive -Path "$stage\state\*" -DestinationPath "$stage\$sid.zip" -Force
  Status 'Package' 'SUCCESS'

  # 4. Upload (split >1.5GB) + verify + atomic latest publish + prune (never drop last good)
  Status 'Upload' 'START'
  $zip = "$stage\$sid.zip"
  $parts = Split-Archive $zip $stage $sid
  $k = 0
  # Finalize part count in BOTH manifest copies, then re-zip so archive matches.
  (Get-Content "$stage\manifest.json" -Raw | ConvertFrom-Json | ForEach-Object {
    $_.parts = $parts.Count; $_
  }) | ConvertTo-Json -Compress | Out-File -LiteralPath "$stage\manifest.json" -Encoding ascii
  Copy-Item -LiteralPath "$stage\manifest.json" -Destination "$stage\state\manifest.json" -Force
  Remove-Item -LiteralPath "$stage\$sid.zip" -Force
  foreach ($old in $parts) { if ($old -ne $zip) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue } }
  Compress-Archive -Path "$stage\state\*" -DestinationPath "$stage\$sid.zip" -Force
  $parts = Split-Archive "$stage\$sid.zip" $stage $sid
  foreach ($p in $parts) {
    $k++
    $rn = "envsnap/$sid" + $(if ($parts.Count -gt 1) { ".part$("{0:000}" -f $k)" } else { '.zip' })
    Storage-UploadFile $be $p $rn | Out-Null
    if ((Storage-FileSize $be $rn) -ne (Get-Item $p).Length) { throw "verify failed for $rn" }
  }
  Storage-UploadFile $be "$stage\manifest.json" "envsnap/$sid.manifest.json" | Out-Null
  # latest pointer: upload new, verify, THEN remove old pointer (atomic-ish, old data kept)
  $ptr = @{ snapshot_id = $sid; parts = $parts.Count; sha256 = $dig; published_utc = (Get-Date).ToUniversalTime().ToString('o') } |
    ConvertTo-Json -Compress
  $ptr | Out-File -LiteralPath "$stage\latest.json" -Encoding ascii -NoNewline
  Storage-UploadFile $be "$stage\latest.json" 'envsnap/latest.json.new' | Out-Null
  if ($BackendType -eq 'LocalDir') {
    Move-Item -LiteralPath (Join-Path $Root 'envsnap\latest.json.new') -Destination (Join-Path $Root 'envsnap\latest.json') -Force
  } else {
    Storage-Delete $be 'envsnap/latest.json' | Out-Null
    Storage-UploadFile $be "$stage\latest.json" 'envsnap/latest.json' | Out-Null
    Storage-Delete $be 'envsnap/latest.json.new' | Out-Null
  }
  Status 'Upload' 'SUCCESS'
  Status 'Publish' 'SUCCESS'

  # 5. Prune: keep Keep newest + always keep previous-known-good (never strand without restore point)
  Status 'Prune' 'START'
  $all = @(Storage-List $be 'envsnap/envsnap-' | Where-Object { $_.name -match '\.manifest\.json$' } | Sort-Object name)
  if ($all.Count -gt ($Keep + 1)) {
    foreach ($old in $all[0..($all.Count - $Keep - 2)]) {
      $osid = ($old.name -replace '^.*[/\\]([^/\\]+)\.manifest\.json$','$1')
      if ($osid -eq $sid -or $osid -eq $prev) { continue }
      Storage-List $be "envsnap/$osid" | ForEach-Object { Storage-Delete $be $_.name | Out-Null }
    }
  }
  Status 'Prune' 'SUCCESS'
  Write-Output "PUBLISH|SNAPSHOT=$sid|STATUS=READY"
} catch {
  # Best-effort orphan cleanup: never leave partial snapshot parts behind.
  # Skipped if latest already points at this snapshot (post-publish prune failure).
  try {
    if ($sid) {
      $be2args = @{ Type = $BackendType }
      if ($BackendType -eq 'LocalDir') { $be2args.Root = $Root } else { $be2args.ApiKey = $env:TG_API_KEY }
      $be2 = New-StorageBackend @be2args
      $live = ''
      try {
        $lt = Join-Path $env:TEMP ("envlive-" + [guid]::NewGuid() + ".json")
        Storage-DownloadFile $be2 'envsnap/latest.json' $lt | Out-Null
        $live = (Get-Content $lt -Raw | ConvertFrom-Json).snapshot_id
        Remove-Item $lt -Force -ErrorAction SilentlyContinue
      } catch {}
      if ($live -ne $sid) {
        Storage-List $be2 $sid | ForEach-Object { Storage-Delete $be2 $_.name | Out-Null }
      }
    }
  } catch {}
  throw
} finally {
  Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
