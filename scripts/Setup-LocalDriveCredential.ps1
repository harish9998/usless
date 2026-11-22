#Requires -Version 5.1
# Setup-LocalDriveCredential.ps1 - store the R: share credential in a DPAPI-encrypted
# blob (~/.usless/smb-cred.blob) that only your Windows user can decrypt.
# Password = the SMB_SHARE_PASSWORD GitHub repo secret (never printed or in a script).
param([string]$Password)
if (-not $Password) {
  Write-Host 'Enter the SMB_SHARE_PASSWORD secret value (input hidden):'
  $sec = Read-Host -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
& "$PSScriptRoot\Secure-Credential.ps1" -Action store -Password $Password
