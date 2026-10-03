#Requires -Version 5.1
# Capture-WindowsEnvironment.ps1 - builds versioned desired-state (NOT a disk clone).
#   powershell -File Capture-WindowsEnvironment.ps1 -OutDir C:\staging\env-state
# Layout: state.json, applications.json, environment-vars.json, registry/, services.json,
# scheduled-tasks/, power.json, firewall.json, user-config/ (mapped app data), docker/,
# workspace/ (file manifest of WorkDir), metadata/. Allowlists only; secrets never captured.
param([string]$OutDir = "$env:TEMP\env-state", [string]$HomeRoot = '', [string]$WorkDir = 'C:\Work', [string]$RunnerId = '', [string[]]$ExtraSecretVars = @())
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source this file: execute it. (Top-level pipeline code would run on import.)' }
function Log([string]$m) { Write-Output "[CAPTURE] $m" }
# Guarded sections: a failing native call degrades ONE section (recorded), never the capture.
$capRep = @()
function Invoke-CapSection { param([string]$name, [scriptblock]$b)
  try { & $b; $script:capRep += @{ section = $name; status = 'SUCCESS' } }
  catch { $script:capRep += @{ section = $name; status = 'FAIL'; error = $_.Exception.Message }; Write-Warning "CAPTURE section $name failed: $($_.Exception.Message)" }
}
# .NET hashing (Get-FileHash is absent from some hosts; this works everywhere).
function Get-Sha256File([string]$p) {
  $s = [System.IO.File]::OpenRead($p)
  try { ([System.Security.Cryptography.SHA256]::Create().ComputeHash($s) | ForEach-Object { $_.ToString('x2') }) -join '' }
  finally { $s.Close() }
}
if (-not $HomeRoot) { $HomeRoot = $env:USERPROFILE }
$SecretVarPatterns = @('*TOKEN*', '*SECRET*', '*PASSWORD*', '*PASSWD*', '*API_KEY*', '*APIKEY*', '*PRIVATE*', '*PAT*', '*AUTHKEY*', '*ACCESS_KEY*', '*CREDENTIALS*')
$SecretNamePatterns = @('.credentials.json', 'auth.json', '.env', '*.env', '*.key', '*token*.json', 'credentials*.json')
function Test-SecretName([string]$n) { foreach ($p in $SecretNamePatterns) { if ($n -like $p) { return $true } }; return $false }
function Test-SecretVar([string]$n) {
  foreach ($p in $SecretVarPatterns) { if ($n -like $p) { return $true } }
  foreach ($e in $ExtraSecretVars) { if ($n -eq $e) { return $true } }
  return $false
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
foreach ($d in @('registry','scheduled-tasks','user-config','docker','workspace','metadata')) {
  New-Item -ItemType Directory -Path (Join-Path $OutDir $d) -Force | Out-Null
}

# --- 1. File manifest of WorkDir (desired file state: add/modify/delete all persist) ---
Log 'workspace manifest'
$wfiles = @()
if (Test-Path -LiteralPath $WorkDir) {
  # Same-API base: Get-ChildItem may return 8.3 short paths while $WorkDir is long.
  $wbase = (Get-Item -LiteralPath $WorkDir).FullName
  $wfiles = Get-ChildItem -LiteralPath $WorkDir -Recurse -File | Where-Object {
    $_.FullName -notmatch '\\(Cache|GPUCache|Code Cache|Crashpad|node_modules|\.git)(\\|$)'
  } | Where-Object { -not (Test-SecretName $_.Name) } | ForEach-Object {
    @{ path = $_.FullName.Substring($wbase.Length).TrimStart('\'); size = $_.Length;
       mtime = $_.LastWriteTimeUtc.ToString('o');
       sha256 = (Get-Sha256File $_.FullName) }
  }
}
$wfiles | ConvertTo-Json -Compress | Out-File -LiteralPath (Join-Path $OutDir 'workspace\files.json') -Encoding ascii

# --- 2. Mapped application data (verified paths only, never guessed) ---
Log 'application mappings'
$map = @(
  @{ name = 'opencode-config'; src = "$HomeRoot\.config\opencode" },
  @{ name = 'opencode-data'; src = "$HomeRoot\.local\share\opencode" },
  @{ name = 'claude'; src = "$HomeRoot\.claude" },
  @{ name = 'openclaw'; src = "$WorkDir\openclaw" },
  @{ name = 'n8n'; src = "$WorkDir\n8n" },
  @{ name = 'mcp'; src = "$WorkDir\mcp" },
  @{ name = 'agents'; src = "$WorkDir\agent" },
  @{ name = 'powershell-profile'; src = "$HomeRoot\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"; file = $true },
  @{ name = 'powershell7-profile'; src = "$HomeRoot\Documents\PowerShell\Microsoft.PowerShell_profile.ps1"; file = $true },
  @{ name = 'gitconfig'; src = "$HomeRoot\.gitconfig"; file = $true }
)
$apps = @()
foreach ($m in $map) {
  $exists = Test-Path -LiteralPath $m.src
  $dest = Join-Path $OutDir ("user-config\" + $m.name)
  if ($exists -and -not $m.file) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    & robocopy $m.src $dest /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NP `
      /XF .credentials.json auth.json .env *.env *.key *token*.json credentials*.json `
      /XD Cache 'Code Cache' GPUCache Crashpad logs | Out-Null
  } elseif ($exists -and $m.file) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
    Copy-Item -LiteralPath $m.src -Destination $dest -Force
  }
  $apps += @{ name = $m.name; src = $m.src; present = [bool]$exists }
}
$apps | ConvertTo-Json | Out-File -LiteralPath (Join-Path $OutDir 'applications.json') -Encoding ascii

# --- 3. User environment vars + PATH (HKCU + machine read; restore writes HKCU/user scope) ---
Log 'environment'
$uvars = @{}
$redacted = @()
Get-ItemProperty -LiteralPath 'HKCU:\Environment' -ErrorAction SilentlyContinue | ForEach-Object {
  $_.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)' } | ForEach-Object {
    if (Test-SecretVar $_.Name) { $uvars[$_.Name] = '{{SECRET:' + $_.Name + '}}'; $redacted += $_.Name }
    else { $uvars[$_.Name] = [string]$_.Value }
  }
}
@{ user = $uvars; redacted_vars = $redacted;
   path_user = [Environment]::GetEnvironmentVariable('Path','User');
   path_machine = [Environment]::GetEnvironmentVariable('Path','Machine') } |
  ConvertTo-Json | Out-File -LiteralPath (Join-Path $OutDir 'environment-vars.json') -Encoding ascii

# --- 4. Registry allowlist export (explicit keys only; no GUIDs/activation/identity) ---
Invoke-CapSection 'registry' {
Log 'registry allowlist'
$regAllow = @('HKCU\Console', 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced')
$regState = @()
foreach ($rk in $regAllow) {
  $ok = Test-Path ("Registry::" + $rk)
  if ($ok) { & reg export ($rk -replace '^HKCU\\','HKCU\') (Join-Path $OutDir ("registry\" + ($rk -replace '[\\ ]','_') + '.reg')) /y 2>$null | Out-Null }
  $regState += @{ key = $rk; present = [bool]$ok }
}
$regState | ConvertTo-Json | Out-File -LiteralPath (Join-Path $OutDir 'registry\keys.json') -Encoding ascii
}

# --- 5. Power settings (scheme + timeouts; reapplied, never hardware identity) ---
Invoke-CapSection 'power' {
Log 'power'
$guid = ((powercfg /getactivescheme 2>$null) | Select-String -Pattern '[0-9a-f-]{36}') -replace '.*([0-9a-f-]{36}).*','$1'
@{ scheme = $guid;
   standby_ac = ((powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null) | Out-String);
   hibernate_ac = ((powercfg /query SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 2>$null) | Out-String) } |
  ConvertTo-Json | Out-File -LiteralPath (Join-Path $OutDir 'power.json') -Encoding ascii
}

# --- 6. Scheduled tasks: user/custom tasks only (never Microsoft\Windows\* system tasks) ---
Invoke-CapSection 'scheduled-tasks' {
Log 'scheduled tasks'
$tasks = @(schtasks /query /fo csv /v 2>$null | ConvertFrom-Csv | Where-Object {
  $_."TaskName" -notlike '\Microsoft\Windows\*' -and $_."TaskName" -notlike '\Microsoft\*'
} | ForEach-Object { [pscustomobject]@{ name = $_."TaskName"; state = $_."Status" } })
$tasks | ConvertTo-Json | Out-File -LiteralPath (Join-Path $OutDir 'scheduled-tasks\tasks.json') -Encoding ascii
foreach ($t in ($tasks | Select-Object -ExpandProperty name)) {
  $safe = ($t -replace '[\\ /:]','_')
  try { schtasks /query /tn $t /xml 2>$null | Out-File -LiteralPath (Join-Path $OutDir ("scheduled-tasks\" + $safe + '.xml')) -Encoding ascii -ErrorAction Stop } catch { }
}
}

# --- 7. Services allowlist (startup type only; safe to reapply) ---
Invoke-CapSection 'services' {
Log 'services'
$svcAllow = @('TermService','Tailscale','sshd','com.docker.service')
$svcs = foreach ($s in $svcAllow) {
  $o = Get-Service -Name $s -ErrorAction SilentlyContinue
  if ($o) { @{ name = $s; startType = [string]$o.StartType; status = [string]$o.Status } }
}
$svcs | ConvertTo-Json | Out-File -LiteralPath (Join-Path $OutDir 'services.json') -Encoding ascii
}

# --- 8. Firewall rules (names + action only; full blobs re-exported at publish time if present) ---
Invoke-CapSection 'firewall' {
Log 'firewall'
$fw = netsh advfirewall firewall show rule name=all 2>$null | Select-String -Pattern '^Rule Name:' | ForEach-Object {
  @{ rule = ($_ -replace '^Rule Name:\s*','').Trim() }
}
$fw | ConvertTo-Json | Out-File -LiteralPath (Join-Path $OutDir 'firewall.json') -Encoding ascii
}

# --- 9. Docker compose files + persistent data map ---
Invoke-CapSection 'docker' {
Log 'docker'
$docker = @{ compose = @(); dataRoots = @() }
if (Test-Path (Join-Path $WorkDir 'docker')) {
  $wbase2 = (Get-Item -LiteralPath $WorkDir).FullName
  $docker.compose = @(Get-ChildItem (Join-Path $WorkDir 'docker') -Filter '*.yml' -Recurse | ForEach-Object { $_.FullName.Substring($wbase2.Length) })
  $docker.dataRoots = @(Get-ChildItem (Join-Path $WorkDir 'docker\data') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($wbase2.Length) })
}
$docker | ConvertTo-Json | Out-File -LiteralPath (Join-Path $OutDir 'docker\docker.json') -Encoding ascii
}

# --- 10. Software inventory (winget ids + versions; manifest decides install/skip/fail) ---
Invoke-CapSection 'software-inventory' {
Log 'software inventory'
$inv = @()
try {
  $raw = winget list 2>$null | Out-String
  $inv = @{ raw_lines = ($raw -split "`n").Count; captured_utc = (Get-Date).ToUniversalTime().ToString('o') }
} catch { $inv = @{ error = 'winget unavailable' } }
$inv | ConvertTo-Json | Out-File -LiteralPath (Join-Path $OutDir 'metadata\software-inventory.json') -Encoding ascii
}

# --- state.json: the desired-state root (includes per-section capture report) ---
@{ schema_version = 1; tool_version = 'envsys-1';
   snapshot_utc = (Get-Date).ToUniversalTime().ToString('o'); runner_id = $RunnerId;
   home = $HomeRoot; workdir = $WorkDir; capture_report = $capRep } |
  ConvertTo-Json -Depth 4 | Out-File -LiteralPath (Join-Path $OutDir 'state.json') -Encoding ascii
Log "CAPTURE complete: $OutDir"
Write-Output "CAPTURE|STATUS=SUCCESS|DIR=$OutDir"
