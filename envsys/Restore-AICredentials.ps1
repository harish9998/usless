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
$profiles = @($env:USERPROFILE, 'C:\Users\RDP') | Where-Object { Test-Path (Split-Path $_ -Parent) } | Select-Object -Unique

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
# --- PC access: restore the runner->PC agent key so the agent can ssh home ---
if (-not [string]::IsNullOrWhiteSpace($env:PC_SSH_KEY_B64)) {
  $keyBytes = [Convert]::FromBase64String($env:PC_SSH_KEY_B64)
  $pcAddr = $env:PC_ADDR
  foreach ($u in $profiles) {
    $sd = Join-Path $u '.ssh'
    New-Item -ItemType Directory $sd -Force | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $sd 'pc-agent-ed25519'), $keyBytes)
    # sshd on Windows requires restrictive perms on private keys
    icacls (Join-Path $sd 'pc-agent-ed25519') /inheritance:r /grant "$($env:USERNAME):R" | Out-Null
  }
  # One-word helper for the agent: C:\Work\pc.ps1 "command"
  New-Item -ItemType Directory 'C:\Work' -Force | Out-Null
  $helper = @"
`$key = Join-Path `$env:USERPROFILE '.ssh\pc-agent-ed25519'
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i `$key -l harishjaswal $pcAddr @args
"@
  Set-Content 'C:\Work\pc.ps1' $helper -Encoding UTF8
  Write-Host "RESTORE|PC|KEY=OK addr=$pcAddr (helper: C:\Work\pc.ps1)"
}

if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN_RESTORE)) {
  [Environment]::SetEnvironmentVariable('GH_TOKEN', $env:GH_TOKEN_RESTORE, 'Machine')
  # sshd holds its env block from service start - restart it so new SSH
  # sessions (incl. future ones) inherit the machine env with GH_TOKEN.
  Restart-Service sshd -Force -ErrorAction SilentlyContinue
  Write-Host 'RESTORE|GH_TOKEN|OK (machine env + sshd restarted)'
}

Write-Host 'RESTORE|BASELINE=DONE'
