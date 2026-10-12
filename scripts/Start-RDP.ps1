#Requires -Version 5.1
# Start-RDP.ps1 - one-command RDP launcher (manual use only).
# Dispatch -> wait -> print where the IP lives. No secrets in this file.
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Start-RDP.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Start-RDP.ps1 -Mode rdp
# Requires: gh CLI authed (gh auth login) OR $env:GH_TOKEN set.
# IP read: Actions log (watchdog prints it) OR connection-card artifact below.
param([ValidateSet('rdp','test','probe','telegram-e2e','snapshot-e2e','restore-e2e')][string]$Mode = 'rdp',
  [string]$Repo = 'harish9998/usless', [string]$Ref = 'main',
  [string]$Workflow = 'win 11 + tailscale + Download.bat script')
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source: execute it.' }
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) { throw 'gh CLI not found. Install it and run: gh auth login' }
& gh workflow run $Workflow --repo $Repo --ref $Ref -f mode=$Mode
if ($LASTEXITCODE -ne 0) { throw 'dispatch failed' }
Write-Output "DISPATCH|MODE=$Mode|REF=$Ref|STATUS=SENT"
Start-Sleep -Seconds 20
$run = & gh run list --repo $Repo --workflow $Workflow --limit 1 | Out-String
Write-Output $run
Write-Output 'Get IP: Actions > run > Verify RDP / watchdog log, or download rdp-connection artifact.'
Write-Output "Connect: mstsc.exe /v:<TAILSCALE_IP>  (user RDP, password = RDP_PASSWORD secret)"
