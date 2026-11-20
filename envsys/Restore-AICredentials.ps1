#Requires -Version 5.1
# Restore-AICredentials.ps1 - login-free boot for AI CLIs.
# Workflow steps run as 'runneradmin' but SSH/terminal users are 'RDP', so the
# baseline is written to EVERY existing user profile + machine-wide env.
# Secrets consumed (set via gh secret set, passed as env by the workflow):
#   OPENCODE_CONFIG_B64  zip{opencode.json}
#   OPENCODE_AUTH_B64    zip{auth.json}
#   QODER_AUTH_B64       zip{qoder_user, qoder_machine_id}
#   GH_TOKEN_RESTORE     raw GitHub PAT for gh CLI on the server
$ErrorActionPreference = 'Continue'

function Restore-Zip {
  param([string]$B64, [string]$DestDir)
  if ([string]::IsNullOrWhiteSpace($B64)) { Write-Host 'RESTORE|SKIP empty-blob'; return $false }
  try {
    $bytes = [Convert]::FromBase64String($B64)
    $zip = Join-Path $env:TEMP '_restore-blob.zip'
    [IO.File]::WriteAllBytes($zip, $bytes)
    if (Test-Path $DestDir) { Remove-Item $DestDir -Recurse -Force -ErrorAction SilentlyContinue }
    Expand-Archive -Path $zip -DestinationPath $DestDir -Force
    return $true
  } catch { Write-Host "RESTORE|FAILED|$($_.Exception.Message)"; return $false }
}

# Which user profiles to seed: current (runneradmin) + the SSH/RDP user
# Seed ALL real user profiles (SSH user may be 'rdp.<hostname>', not 'RDP')
$skip = @('Public','Default','Default User','All Users','installer')
$profiles = @($env:USERPROFILE, 'C:\Users\RDP') + @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | Where-Object { $skip -notcontains $_.Name } | ForEach-Object { $_.FullName }) | Select-Object -Unique | Where-Object { Test-Path $_ }

# --- opencode: config (providers/keys) + auth store ---
$ocCfg  = Restore-Zip $env:OPENCODE_CONFIG_B64 (Join-Path $env:TEMP '_occfg')
$ocAuth = Restore-Zip $env:OPENCODE_AUTH_B64   (Join-Path $env:TEMP '_ocauth')
$qAuth  = Restore-Zip $env:QODER_AUTH_B64      (Join-Path $env:TEMP '_qauth')
foreach ($u in $profiles) {
  if ($ocCfg) {
    $d = Join-Path $u '.config\opencode'
    New-Item -ItemType Directory $d -Force | Out-Null
    Copy-Item (Join-Path $env:TEMP '_occfg\opencode.json') $d -Force
  }
  if ($ocAuth) {
    $d = Join-Path $u '.local\share\opencode'
    New-Item -ItemType Directory $d -Force | Out-Null
    Copy-Item (Join-Path $env:TEMP '_ocauth\auth.json') $d -Force
  }
  # --- qoder (INTL CLI): .auth\user + machine_id ---
  if ($qAuth) {
    $qd = Join-Path $u '.qoder\.auth'
    New-Item -ItemType Directory $qd -Force | Out-Null
    Copy-Item (Join-Path $env:TEMP '_qauth\qoder_user') (Join-Path $qd 'user') -Force
    Copy-Item (Join-Path $env:TEMP '_qauth\qoder_machine_id') (Join-Path $qd 'machine_id') -Force
  }
  # --- git identity: write directly into that user's .gitconfig ---
  $gitcfg = Join-Path $u '.gitconfig'
  git config --file $gitcfg user.name 'harish9998'
  git config --file $gitcfg user.email 'Harishvideoexpert@gmail.com'
}
Write-Host "RESTORE|OPENCODE|CONFIG=$(if ($ocCfg) {'OK'} else {'SKIP'})"
Write-Host "RESTORE|OPENCODE|AUTH=$(if ($ocAuth) {'OK'} else {'SKIP'})"
Write-Host "RESTORE|QODER|AUTH=$(if ($qAuth) {'OK'} else {'SKIP'})"
Write-Host "RESTORE|USERS|SEEDED=$($profiles -join ',')"

# --- gh CLI token: machine-wide env so ANY user (incl. SSH sessions) has it ---
# --- PC access: full + scoped keys so runner agent can use PC (files/apps/MCP/tunnels) per policy ---
if (-not [string]::IsNullOrWhiteSpace($env:PC_SSH_KEY_B64)) {
  $pcAddr = if ($env:PC_ADDR) { $env:PC_ADDR } else { '100.111.187.124' }
  $pcUser = if ($env:PC_USER) { $env:PC_USER } else { 'harishjaswal' }
  foreach ($u in $profiles) {
    $sd = Join-Path $u '.ssh'; New-Item -ItemType Directory $sd -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $sd 'pc-agent-ed25519'), [Convert]::FromBase64String($env:PC_SSH_KEY_B64))
    if ($env:PC_SSH_SCOPED_KEY_B64) {
      [IO.File]::WriteAllBytes((Join-Path $sd 'pc-agent-scoped-ed25519'), [Convert]::FromBase64String($env:PC_SSH_SCOPED_KEY_B64))
    }
    foreach ($kf in @('pc-agent-ed25519','pc-agent-scoped-ed25519')) {
      $kp = Join-Path $sd $kf; if (Test-Path $kp) { icacls $kp /inheritance:r /grant "$($env:USERNAME):R" 2>$null | Out-Null }
    }
  }
  New-Item -ItemType Directory 'C:\Work' -Force | Out-Null
  # pc.ps1 = FULL access (arbitrary commands, SSH tunnels). Use only when needed.
  @"
`$key = Join-Path `$env:USERPROFILE '.ssh\pc-agent-ed25519'
ssh -o StrictHostKeyChecking=accept-new -i `$key -l $pcUser $pcAddr @args
"@ | Set-Content 'C:\Work\pc.ps1' -Encoding UTF8
  # pcx.ps1 = SCOPED access via gateway policy (ls/read/write/run/apps/tunnels-info). Default for agent.
  @"
`$key = Join-Path `$env:USERPROFILE '.ssh\pc-agent-scoped-ed25519'
if (-not (Test-Path `$key)) { `$key = Join-Path `$env:USERPROFILE '.ssh\pc-agent-ed25519' }
`$cmd = if (`$args.Count -gt 0) { `$args -join ' ' } else { 'help' }
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i `$key -l $pcUser $pcAddr `$cmd
"@ | Set-Content 'C:\Work\pcx.ps1' -Encoding UTF8
  # pc-tunnel.ps1 = forward a PC localhost port to runner localhost (for MCP/model bridges)
  @'
param([Parameter(Mandatory=$true)][int]$Port, [int]$LocalPort = $Port)
$key = Join-Path $env:USERPROFILE '.ssh\pc-agent-ed25519'
$addr = '__PC_ADDR__'; $user = '__PC_USER__'
Write-Output "TUNNEL localhost:$LocalPort -> ${user}@${addr}:127.0.0.1:$Port (Ctrl+C to stop)"
ssh -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -N -L "${LocalPort}:127.0.0.1:${Port}" -i $key -l $user $addr
'@.Replace('__PC_ADDR__',$pcAddr).Replace('__PC_USER__',$pcUser) | Set-Content 'C:\Work\pc-tunnel.ps1' -Encoding UTF8
  # pc-send/get helpers (scp over full key)
  @'
param([Parameter(Mandatory=$true)][string]$Local, [string]$Remote = "C:/Users/harishjaswal/Downloads/RDP-Inbox/")
$key = Join-Path $env:USERPROFILE ".ssh\pc-agent-ed25519"
scp -o StrictHostKeyChecking=accept-new -i $key $Local "__PC_USER__@__PC_ADDR__:$Remote"
'@.Replace('__PC_USER__',$pcUser).Replace('__PC_ADDR__',$pcAddr) | Set-Content 'C:\Work\pc-send.ps1' -Encoding UTF8
  @'
param([Parameter(Mandatory=$true)][string]$Remote, [string]$Local = ".")
$key = Join-Path $env:USERPROFILE ".ssh\pc-agent-ed25519"
scp -o StrictHostKeyChecking=accept-new -i $key "__PC_USER__@__PC_ADDR__:$Remote" $Local
'@.Replace('__PC_USER__',$pcUser).Replace('__PC_ADDR__',$pcAddr) | Set-Content 'C:\Work\pc-get.ps1' -Encoding UTF8
  # Persistent agent note: this is an ephemeral runner, NOT the user's PC
  @"
# AGENT ENVIRONMENT (read this first)
- **You are on an ephemeral GitHub Actions Windows runner** (user like RDP/runneradmin, wiped every ~6h). `C:\Users\HARISHJASWAL\...` does NOT exist here.
- **The user's real PC** is reachable over Tailscale at $pcUser@$pcAddr (only when PC is on + sshd running). PC files live under `C:\Users\HARISHJASWAL\` on the PC, not here.
- **To access PC files/apps, ALWAYS use the PC bridge helpers** (do NOT search the runner's local disk for user files):
  - List/find: `powershell -File C:\Work\pcx.ps1 "ls C:\Users\HARISHJASWAL\Downloads"` (read-allowlisted dirs)
  - Read: `powershell -File C:\Work\pcx.ps1 "read C:\Users\HARISHJASWAL\path\to\file"`
  - Search on PC: `powershell -File C:\Work\pc.ps1 "Get-ChildItem C:\Users\HARISHJASWAL -Recurse -Filter '*.zip' -ErrorAction SilentlyContinue | Select-Object -First 20 FullName"`
  - Copy from PC to runner: `powershell -File C:\Work\pc-get.ps1 "C:/Users/HARISHJASWAL/Downloads/file.zip" "C:\Work\"`
  - Copy to PC: `powershell -File C:\Work\pc-send.ps1 "C:\Work\out.mp4"` (lands in PC Downloads\RDP-Inbox)
  - Run PC apps: `powershell -File C:\Work\pcx.ps1 "run blender -b ..."`, `pcx "launch robloxstudio"`, `pcx "render blender <.blend> -f 1"`
  - Full PC shell (when needed): `powershell -File C:\Work\pc.ps1 "<command>"`
- **Permissions** are controlled by the user on their PC (`~\.config\pc-agent\policy.json`). If a path/app is DENY'd, tell the user what to allow — do not try to bypass.
- **Runner-local work dir:** use `C:\Work\` for processing here; copy results back to PC before session ends (runner is ephemeral).
"@ | Set-Content 'C:\Work\AGENT-ENV.md' -Encoding UTF8
  Write-Host "RESTORE|PC|addr=$pcAddr full=OK scoped=$([bool]$env:PC_SSH_SCOPED_KEY_B64) helpers=pc.ps1,pcx.ps1,pc-tunnel.ps1,pc-send.ps1,pc-get.ps1 note=C:\Work\AGENT-ENV.md"
  # Compute offload helper (runner -> PC) - copy from repo checkout into C:\Work
  $offloadSrc = Join-Path $PSScriptRoot 'pc-offload.ps1'
  if (Test-Path $offloadSrc) { Copy-Item $offloadSrc 'C:\Work\pc-offload.ps1' -Force; Write-Host 'RESTORE|PC|OFFLOAD=OK (C:\Work\pc-offload.ps1)' }
  $tunnelSrc = Join-Path $PSScriptRoot 'omni-tunnel.ps1'
  if (Test-Path $tunnelSrc) { Copy-Item $tunnelSrc 'C:\Work\omni-tunnel.ps1' -Force; Write-Host 'RESTORE|OMNI|TUNNEL=OK (C:\Work\omni-tunnel.ps1)' }
}

if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN_RESTORE)) {
  [Environment]::SetEnvironmentVariable('GH_TOKEN', $env:GH_TOKEN_RESTORE, 'Machine')
  # sshd holds its env block from service start - restart it so new SSH
  # sessions (incl. future ones) inherit the machine env with GH_TOKEN.
  Restart-Service sshd -Force -ErrorAction SilentlyContinue
  Write-Host 'RESTORE|GH_TOKEN|OK (machine env + sshd restarted)'
}

Write-Host 'RESTORE|BASELINE=DONE'
