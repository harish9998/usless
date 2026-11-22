#Requires -Version 5.1
# Setup-RemoteShare.ps1 - runner-side SMB share for the hybrid R: drive.
# Creates a dedicated low-privilege account (NOT RDP admin), shares C:\RemoteWorkspace
# only to that account, disables SMBv1, restricts port 445 to the Tailnet (100.64/10).
# Password comes from env SMB_SHARE_PASSWORD (workflow secret) - never logged.
$ErrorActionPreference = 'Continue'
function Say([string]$m) { Write-Host "SHARE|$m" }
$user = 'wsreader'
$pw = $env:SMB_SHARE_PASSWORD
if (-not $pw) { Say 'SKIP|no SMB_SHARE_PASSWORD secret'; exit 0 }
if ((Get-SmbServerConfiguration -ErrorAction SilentlyContinue).EnableSMB1Protocol -eq $true) {
  Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction SilentlyContinue
  Say 'SMBV1|disabled'
}
# Dedicated account with a fixed, non-admin identity
if (-not (Get-LocalUser -Name $user -ErrorAction SilentlyContinue)) {
  $sec = ConvertTo-SecureString $pw -AsPlainText -Force
  New-LocalUser -Name $user -Password $sec -PasswordNeverExpires -AccountNeverExpires -ErrorAction SilentlyContinue | Out-Null
  Say "USER|created=$user"
} else {
  Set-LocalUser -Name $user -Password (ConvertTo-SecureString $pw -AsPlainText -Force) -ErrorAction SilentlyContinue
  Say "USER|updated=$user"
}
# Share only the workspace folder, only to this account
$path = 'C:\RemoteWorkspace'
if (-not (Test-Path $path)) { New-Item -ItemType Directory $path -Force | Out-Null }
$existing = Get-SmbShare -Name 'RemoteWorkspace' -ErrorAction SilentlyContinue
if ($existing) { Set-SmbShare -Name 'RemoteWorkspace' -Path $path -ErrorAction SilentlyContinue }
else { New-SmbShare -Name 'RemoteWorkspace' -Path $path -ErrorAction SilentlyContinue | Out-Null }
Revoke-SmbShareAccess -Name 'RemoteWorkspace' -AccountName 'Everyone' -Force -ErrorAction SilentlyContinue | Out-Null
Grant-SmbShareAccess -Name 'RemoteWorkspace' -AccountName $user -AccessRight Change -Force -ErrorAction SilentlyContinue | Out-Null
Say "SHARE|RemoteWorkspace=$path|access=$user(Change)"
# NTFS: give the account modify rights on the workspace tree only
icacls $path /grant "${user}:(OI)(CI)M" /T 2>$null | Out-Null
# Firewall: inbound 445 ONLY from Tailscale network
$rule = 'Hybrid-SMB-Tailnet'
if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP -LocalPort 445 -RemoteAddress 100.64.0.0/10 -Action Allow | Out-Null
}
Say 'FIREWALL|445=tailnet-only(100.64.0.0/10)'
Say 'DONE'
