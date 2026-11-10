#Requires -Version 5.1
# Bootstrap-Runner.ps1 - ONE-CLICK runner setup. Idempotent, no password needed.
# Ensures: local SSH key -> SSH_PUBLIC_KEY secret -> fresh runner (optional) -> connect.
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Bootstrap-Runner.ps1          # key + secret only
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Bootstrap-Runner.ps1 -New     # also dispatch fresh runner + wait
#   Add -SSH (Launch-RDP.ps1) or run scripts\Launch-RDP.ps1 -Ssh after to connect.
param(
  [string]$Repo = 'harish9998/usless',
  [switch]$New
)
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source: execute it.' }

# 1. Local SSH key (create if missing)
$key = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
if (-not (Test-Path $key)) {
  Write-Output 'STEP|ssh-key=GENERATING'
  ssh-keygen -q -t ed25519 -N '""' -f $key -C "$env:USERNAME-runner-ssh"
} else { Write-Output 'STEP|ssh-key=EXISTS' }
$pub = (Get-Content "$key.pub" -Raw).Trim()

# 2. Repo secret SSH_PUBLIC_KEY (set only if missing/different)
$ghAuth = gh auth status 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw 'gh CLI not authed. Run: gh auth login' }
try { $cur = gh secret list --repo $Repo --json name | ConvertFrom-Json | Where-Object { $_.name -eq 'SSH_PUBLIC_KEY' } } catch { $cur = $null }
if ($cur) { Write-Output 'STEP|secret=EXISTS (already set; rotate with: gh secret set SSH_PUBLIC_KEY)' }
else {
  gh secret set SSH_PUBLIC_KEY --repo $Repo --body $pub
  Write-Output 'STEP|secret=SET'
}

# 3. Tailscale client check (needs to be on the tailnet to reach 100.x.x.x)
$ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
if (-not (Test-Path $ts)) { Write-Warning 'Tailscale client missing locally - install from https://tailscale.com and login.' }
else { Write-Output "STEP|tailscale=$(& $ts ip -4 | Select-Object -First 1)" }

# 4. Fresh runner (optional)
if ($New) {
  & "$PSScriptRoot\Start-RDP.ps1" -Mode rdp
  Write-Output 'STEP|dispatch=SENT (2-4 min; then: Launch-RDP.ps1 -Ssh)'
} else {
  Write-Output 'BOOTSTRAP-STATUS=READY (terminal access needs no password)'
}

# 5. Connect now (terminal, no password)
& "$PSScriptRoot\Launch-RDP.ps1" -Ssh
