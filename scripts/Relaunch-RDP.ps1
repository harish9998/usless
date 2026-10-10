#Requires -Version 5.1
# Relaunch-RDP.ps1 - MANUAL trigger helper for the persistent-RDP workflow.
# This script only *requests* a new runner via the GitHub API; nothing here
# survives runner death, and there is no automatic rebirth. Use one of:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Relaunch-RDP.ps1                 # RDP desktop
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Relaunch-RDP.ps1 -Mode test      # regression run
# Requires: gh CLI authenticated (gh auth login) OR $env:GH_TOKEN set. No secrets are
# pasted into this file; dispatch uses your local gh credentials only.
param([ValidateSet('rdp', 'test')][string]$Mode = 'rdp',
  [string]$Repo = 'harish9998/usless', [string]$Ref = 'main',
  [string]$Workflow = 'win 11 + tailscale + Download.bat script')
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source this file: execute it.' }
$gh = Get-Command gh -ErrorAction SilentlyContinue
if (-not $gh) { throw 'gh CLI not found. Install it and run: gh auth login' }
& gh workflow run $Workflow --repo $Repo --ref $Ref -f mode=$Mode
if ($LASTEXITCODE -ne 0) { throw 'dispatch failed' }
Start-Sleep -Seconds 15
$runs = & gh run list --repo $Repo --workflow $Workflow --limit 1 | Out-String
Write-Output "DISPATCH|MODE=$Mode|REF=$Ref|STATUS=SENT"
Write-Output $runs
Write-Output 'Watch progress in the Actions tab. RDP IP prints in the watchdog step log.'
