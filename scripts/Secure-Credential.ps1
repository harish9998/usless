#Requires -Version 5.1
# Secure-Credential.ps1 - store/read the R: share password with DPAPI (no PS Security module).
# Usage: Secure-Credential.ps1 -Action store -Password <pw>
#        Secure-Credential.ps1 -Action read   (prints password to stdout - pipe only)
param([ValidateSet('store','read')][string]$Action, [string]$Password)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$file = "$env:USERPROFILE\.usless\smb-cred.blob"
$entropy = [Text.Encoding]::UTF8.GetBytes('usless-hybrid-rdrive-v1')
if ($Action -eq 'store') {
  if (-not $Password) { throw 'store needs -Password' }
  New-Item -ItemType Directory (Split-Path $file) -Force | Out-Null
  $bytes = [Text.Encoding]::UTF8.GetBytes($Password)
  $enc = [Security.Cryptography.ProtectedData]::Protect($bytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
  [IO.File]::WriteAllBytes($file, $enc)
  Write-Output "CREDENTIAL|stored=$file|DPAPI-CurrentUser"
} else {
  if (-not (Test-Path $file)) { Write-Output 'CREDENTIAL|MISSING'; exit 1 }
  $enc = [IO.File]::ReadAllBytes($file)
  $dec = [Security.Cryptography.ProtectedData]::Unprotect($enc, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
  [Text.Encoding]::UTF8.GetString($dec)
}
