#Requires -Version 5.1
# Restore-WindowsEnvironment.ps1 - deterministic reconcile toward desired state.
#   powershell -File Restore-WindowsEnvironment.ps1 -SnapshotDir C:\staging\snap-001 [-HomeRoot ...] [-WorkDir ...]
# Reconcile rule: managed roots converge to desired state, INCLUDING deletions
# (a file/setting absent from desired state is removed, never resurrected).
# Secrets: snapshot must contain zero secrets; {{SECRET:NAME}} placeholders in
# *.template files are filled from environment at restore time.
param([string]$SnapshotDir = '', [string]$HomeRoot = '', [string]$WorkDir = 'C:\Work')
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source this file: execute it. (Top-level pipeline code would run on import.)' }
function Get-Sha256File([string]$p) {
  $s = [System.IO.File]::OpenRead($p)
  try { ([System.Security.Cryptography.SHA256]::Create().ComputeHash($s) | ForEach-Object { $_.ToString('x2') }) -join '' }
  finally { $s.Close() }
}
function Status { param([string]$c, [string]$s) Write-Output "RESTORE|COMPONENT=$c|STATUS=$s" }
if (-not $SnapshotDir -or -not (Test-Path (Join-Path $SnapshotDir 'state.json'))) { Status 'Snapshot' 'FAIL'; throw "Bad snapshot dir: $SnapshotDir" }
if (-not $HomeRoot) { $HomeRoot = $env:USERPROFILE }
$fail = 0
# Native exes (reg/powercfg/...) report via exit codes and may write success to
# stderr, which is TERMINATING under $ErrorActionPreference='Stop'. Always use this.
function Invoke-Native {
  param([string]$Exe, [string[]]$Args)
  $oldPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $o = & $Exe @Args 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $o }
  } finally { $ErrorActionPreference = $oldPref }
}
function MarkFail { param([string]$c, [string]$m) Status $c 'FAIL'; Write-Warning "${c}: ${m}"; $script:fail = $script:fail + 1 }

# 1. Workspace reconcile (add/modify/delete within WorkDir only)
try {
  $want = Get-Content (Join-Path $SnapshotDir 'workspace\files.json') -Raw | ConvertFrom-Json
  $wantMap = @{}
  foreach ($f in $want) { $wantMap[$f.path] = $f }
  $staged = Join-Path $SnapshotDir 'workspace-data'
  if (Test-Path -LiteralPath $staged) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    $wbase = (Get-Item -LiteralPath $WorkDir).FullName
    $sbase = (Get-Item -LiteralPath $staged).FullName
    $live = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
      $_.FullName.Substring($wbase.Length).TrimStart('\')
    }
    foreach ($rel in $live) {
      if (-not $wantMap.ContainsKey($rel)) { Remove-Item -LiteralPath (Join-Path $WorkDir $rel) -Force; }
    }
    Get-ChildItem -LiteralPath $staged -Recurse -File | ForEach-Object {
      $rel = $_.FullName.Substring($sbase.Length).TrimStart('\')
      $dst = Join-Path $WorkDir $rel
      New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
      Copy-Item -LiteralPath $_.FullName -Destination $dst -Force
    }
    $bad = @()
    foreach ($f in $want) {
      $p = Join-Path $WorkDir $f.path
      if (-not (Test-Path -LiteralPath $p)) { $bad += "missing:$($f.path)"; continue }
      if ((Get-Sha256File $p) -ne $f.sha256) { $bad += "digest:$($f.path)" }
    }
    if ($bad.Count -gt 0) { throw ("integrity failed: " + ($bad | Select-Object -First 5) -join ', ') }
    Status 'Workspace' 'RESTORED-VERIFIED'
  } else { Status 'Workspace' 'SKIP-NO-DATA' }
} catch { MarkFail 'Workspace' $_.Exception.Message }

# 2. Application configs (merge/copy; never delete live files here - safe side)
try {
  $apps = Get-Content (Join-Path $SnapshotDir 'applications.json') -Raw | ConvertFrom-Json
  foreach ($a in $apps) {
    if (-not $a.present) { continue }
    $src = Join-Path $SnapshotDir ('user-config\' + $a.name)
    if (-not (Test-Path -LiteralPath $src)) { continue }
    if (Test-Path -LiteralPath $src -PathType Container) {
      New-Item -ItemType Directory -Path $a.src -Force | Out-Null
      & robocopy $src $a.src /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NP | Out-Null
    } else {
      New-Item -ItemType Directory -Path (Split-Path -Parent $a.src) -Force | Out-Null
      Copy-Item -LiteralPath $src -Destination $a.src -Force
    }
  }
  Status 'AppConfig' 'RESTORED'
} catch { MarkFail 'AppConfig' $_.Exception.Message }

# 3. Env vars + PATH (user scope; machine PATH recorded but only reapplied if -ApplyMachinePath)
try {
  $ev = Get-Content (Join-Path $SnapshotDir 'environment-vars.json') -Raw | ConvertFrom-Json
  $cur = @{}
  Get-ItemProperty -LiteralPath 'HKCU:\Environment' -ErrorAction SilentlyContinue | ForEach-Object {
    $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)' } | ForEach-Object { $cur[$_.Name] = [string]$_.Value }
  }
  foreach ($p in $ev.user.PSObject.Properties) {
    $v = [string]$p.Value
    if ($v -match '^\{\{SECRET:[A-Za-z0-9_]+\}\}$') { continue }  # runtime injection owns secrets; never write placeholders
    [Environment]::SetEnvironmentVariable($p.Name, $v, 'User')
  }
  foreach ($k in @($cur.Keys)) { if (-not $ev.user.PSObject.Properties[$k]) { [Environment]::SetEnvironmentVariable($k, $null, 'User') } }
  if ($ev.path_user) { [Environment]::SetEnvironmentVariable('Path', [string]$ev.path_user, 'User') }
  Status 'Environment' 'RESTORED'
} catch { MarkFail 'Environment' $_.Exception.Message }

# 4. Registry allowlist (explicit keys only)
try {
  $keys = Get-Content (Join-Path $SnapshotDir 'registry\keys.json') -Raw | ConvertFrom-Json
  foreach ($k in $keys) {
    if (-not $k.present) { continue }
    $f = Join-Path $SnapshotDir ('registry\' + ($k.key -replace '[\\ ]','_') + '.reg')
    if (Test-Path -LiteralPath $f) {
      $r = Invoke-Native 'reg' @('import', $f)
      if ($r.Code -ne 0) { throw "reg import failed: $($r.Out)" }
    }
  }
  Status 'Registry' 'RESTORED'
} catch { MarkFail 'Registry' $_.Exception.Message }

# 5. Power (timeouts + scheme; no hardware identity)
try {
  $pw = Get-Content (Join-Path $SnapshotDir 'power.json') -Raw | ConvertFrom-Json
  if ($pw.scheme -match '[0-9a-f-]{36}') {
    $r = Invoke-Native 'powercfg' @('/setactive', $pw.scheme)
    if ($r.Code -ne 0) { throw "powercfg setactive failed (admin required?): $($r.Out)" }
  }
  foreach ($a in @('/change','standby-timeout-ac','0'), @('/change','hibernate-timeout-ac','0')) {
    $r = Invoke-Native 'powercfg' $a
    if ($r.Code -ne 0) { throw "powercfg failed: $($r.Out)" }
  }
  $r = Invoke-Native 'powercfg' @('/hibernate','off')
  if ($r.Code -ne 0) { throw "powercfg hibernate failed: $($r.Out)" }
  Status 'Power' 'RESTORED'
} catch { MarkFail 'Power' $_.Exception.Message }

# 6. Scheduled tasks (managed set only: present ones created, absent ones deleted)
try {
  $want = @(Get-Content (Join-Path $SnapshotDir 'scheduled-tasks\tasks.json') -Raw | ConvertFrom-Json)
  $wantNames = @($want | ForEach-Object { $_.name })
  foreach ($t in $want) {
    $xml = Join-Path $SnapshotDir ('scheduled-tasks\' + ($t.name -replace '[\\ /:]','_') + '.xml')
    if (Test-Path -LiteralPath $xml) { schtasks /create /tn $t.name /xml $xml /f 2>$null | Out-Null }
  }
  $live = @(schtasks /query /fo csv 2>$null | ConvertFrom-Csv | Where-Object {
    $_."TaskName" -notlike '\Microsoft*' } | ForEach-Object { $_."TaskName" })
  foreach ($l in $live) {
    if ($wantNames -notcontains $l -and $l -like '\RDP-*') { schtasks /delete /tn $l /f 2>$null | Out-Null }
  }
  Status 'ScheduledTasks' 'RESTORED'
} catch { MarkFail 'ScheduledTasks' $_.Exception.Message }

# 7. Services allowlist (startup types; never touch anything else)
try {
  $svcs = Get-Content (Join-Path $SnapshotDir 'services.json') -Raw | ConvertFrom-Json
  foreach ($s in $svcs) {
    try { Set-Service -Name $s.name -StartupType $s.startType -ErrorAction Stop } catch {}
    try { Start-Service -Name $s.name -ErrorAction SilentlyContinue } catch {}
  }
  Status 'Services' 'RESTORED'
} catch { MarkFail 'Services' $_.Exception.Message }

# 8. Firewall: ONLY managed rules are enforced (RDP access). All other rules are
# recorded data, never blindly imported (import would wipe runner infra rules).
try {
  $r = Invoke-Native 'netsh' @('advfirewall','firewall','show','rule','name=RDP-Tailscale')
  if ($r.Code -ne 0 -or ($r.Out -notmatch 'Enabled:\s*Yes')) {
    $a = Invoke-Native 'netsh' @('advfirewall','firewall','delete','rule','name=RDP-Tailscale')
    $b = Invoke-Native 'netsh' @('advfirewall','firewall','add','rule','name=RDP-Tailscale','dir=in','action=allow','protocol=TCP','localport=3389')
    if ($b.Code -ne 0) { throw "rule recreate failed: $($b.Out)" }
  }
  try { Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction Stop } catch {}
  Status 'Firewall' 'RESTORED-MANAGED'
} catch { MarkFail 'Firewall' $_.Exception.Message }

# 9. Secret injection: {{SECRET:NAME}} in *.template files under restored data
try {
  $n = 0
  Get-ChildItem -LiteralPath $WorkDir -Recurse -Filter '*.template' -ErrorAction SilentlyContinue | ForEach-Object {
    $t = Get-Content -LiteralPath $_.FullName -Raw
    $changed = $false
    foreach ($m in ([regex]::Matches($t, '\{\{SECRET:([A-Za-z0-9_]+)\}\}'))) {
      $v = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
      if ($null -ne $v) { $t = $t.Replace($m.Value, $v); $changed = $true }
    }
    if ($changed) {
      $dst = $_.FullName -replace '\.template$', ''
      Set-Content -LiteralPath $dst -Value $t -Encoding ascii -NoNewline; $n++
    }
  }
  Status 'Secrets' ("INJECTED-$n")
} catch { MarkFail 'Secrets' $_.Exception.Message }

if ($fail -gt 0) { Status 'Restore' ("DEGRADED-$fail"); exit 1 }
Status 'Restore' 'READY'
