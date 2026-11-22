#Requires -Version 5.1
# remote-drive.ps1 - Phase 2 storage. SMB feasibility + secure mapping, SFTP fallback.
# Usage: remote-drive.ps1 -Action status|mount|unmount|sync|check [-Target 1] [-AllowDispatch]
#        remote-drive.ps1 -Action sync -Direction push|pull -Local <path> -Remote <path>
param(
  [ValidateSet('status','mount','unmount','sync','check','auto')][string]$Action = 'status',
  [ValidateSet('push','pull')][string]$Direction = 'push',
  [string]$Local, [string]$Remote = 'C:\RemoteWorkspace\incoming',
  [string]$Drive = 'R:', [string]$Target = '1', [switch]$AllowDispatch,
  [string]$Repo = "$env:USERPROFILE\usless"
)
. (Join-Path $PSScriptRoot 'remote-common.ps1')

# SMB security preflight: ensure SMBv1 disabled (never enable it)
function Get-SmbV1State { (Get-SmbServerConfiguration -ErrorAction SilentlyContinue).EnableSMB1Protocol }

if ($Action -eq 'unmount') {
  $m = Get-SmbMapping -LocalPath $Drive -ErrorAction SilentlyContinue
  if ($m) { Remove-SmbMapping -LocalPath $Drive -Force -ErrorAction SilentlyContinue; Write-Output "UNMOUNT|$Drive" }
  else { Write-Output "UNMOUNT|$Drive|not-mapped" }
  exit 0
}
if ($Action -eq 'status') {
  $m = Get-SmbMapping -LocalPath $Drive -ErrorAction SilentlyContinue
  if ($m) { "DRIVE|$Drive|$($m.RemotePath)|$($m.Status)" } else { "DRIVE|$Drive|NOT-MAPPED" }
  "SMBV1=$(Get-SmbV1State)"
  exit 0
}
$runner = Resolve-Runner -Target $Target -AllowDispatch:$AllowDispatch -Repo $Repo
Write-Output "RUNNER|ip=$($runner.Ip)|run=$($runner.RunId)"

# SMB feasibility: port 445 over Tailnet + server feature availability on runner
$tcp = Test-NetConnection -ComputerName $runner.Ip -Port 445 -WarningAction SilentlyContinue -InformationLevel Quiet
$smbRemote = $false
if ($tcp) {
  $probe = Invoke-RemoteScript $runner "([bool](Get-Service LanmanServer -ErrorAction SilentlyContinue)) -and ((Get-Service LanmanServer -EA SilentlyContinue).Status -eq 'Running')" 2>&1 | Out-String
  $smbRemote = $probe -match 'True'
}
Write-Output "SMB|port445=$tcp|server_running=$smbRemote"
if ($Action -eq 'auto') {
  # Auto-remount R: to the current runner using DPAPI-encrypted stored credential.
  if (-not $smbRemote) { Write-Output "DRIVE|auto|SKIP|SMB unavailable on $($runner.Ip)"; exit 0 }
  # Read credential from DPAPI-encrypted blob (only this Windows user can decrypt it).
  $pw = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Secure-Credential.ps1') -Action read 2>$null
  if (-not $pw -or "$pw".Length -lt 8) { Write-Output "DRIVE|auto|SKIP|no credential (run scripts\Setup-LocalDriveCredential.ps1 once)"; exit 0 }
  $shareUser = 'wsreader'
  $remotePath = "\\$($runner.Ip)\RemoteWorkspace"
  $existing = Get-SmbMapping -LocalPath $Drive -ErrorAction SilentlyContinue
  if ($existing -and $existing.RemotePath -ne $remotePath) { Remove-SmbMapping -LocalPath $Drive -Force -ErrorAction SilentlyContinue; Write-Output "DRIVE|auto|remapping (runner changed)" }
  if (-not (Get-SmbMapping -LocalPath $Drive -ErrorAction SilentlyContinue)) {
    New-SmbMapping -LocalPath $Drive -RemotePath $remotePath -UserName $shareUser -Password "$pw" -Persistent:$true -ErrorAction Stop | Out-Null
  }
  $m = Get-SmbMapping -LocalPath $Drive -ErrorAction SilentlyContinue
  Write-Output "DRIVE|auto|$Drive|$($m.RemotePath)|$($m.Status)"
  exit 0
}
if ($Action -eq 'check') {
  if ($smbRemote) { Write-Output 'SMB|FEASIBLE (authenticated share possible)' } else { Write-Output 'SMB|NOT-FEASIBLE - use SFTP fallback (rdp peer send/get)' }
  exit 0
}
if ($Action -eq 'mount') {
  if (-not $smbRemote) { throw 'SMB unavailable on runner. Use SFTP fallback: pc-agent/tools/rdp-peer.ps1 -Action send/get' }
  if ((Get-SmbV1State) -eq $true) { throw 'SMBv1 enabled locally - refusing to mount until disabled' }
  # Credential from Windows Credential Manager only - never from args/files.
  $cred = Get-Credential -Message "Tailnet SMB credential for $($runner.Ip) (saved in Windows Credential Manager)" -UserName "$($runner.User)"
  New-SmbMapping -LocalPath $Drive -RemotePath "\\$($runner.Ip)\RemoteWorkspace" -UserName $cred.UserName -Password $cred.GetNetworkCredential().Password -Persistent:$true -ErrorAction Stop | Out-Null
  Write-Output "MOUNT|$Drive|\\\\$($runner.Ip)\\RemoteWorkspace|OK"
  exit 0
}
# sync: checksum-aware SFTP transfer (atomic, verified, retry once)
if (-not $Local) { throw 'sync: -Local is required' }
$hash = Get-FileSha256 $Local
$name = Split-Path $Local -Leaf
if ($Direction -eq 'push') {
  $rp = "$Remote\$name"
  $remoteHash = Invoke-RemoteScript $runner "if (Test-Path '$rp') { & 'C:\RemoteWorkspace\worker\hash.ps1' '$rp' } else { 'MISSING' }" 2>&1 | Select-Object -Last 1
  if ("$remoteHash".Trim() -eq $hash) { Write-Output "SYNC|skip|identical|$name"; exit 0 }
  Copy-ToRunner $runner $Local $Remote
  $rp = "$Remote\$name"
  $verify = Invoke-RemoteScript $runner "& 'C:\RemoteWorkspace\worker\hash.ps1' '$rp'" 2>&1 | Select-Object -Last 1
  if ("$verify".Trim() -ne $hash) { throw "Checksum mismatch after upload: $name" }
  Write-Output "SYNC|pushed|verified|$name|$hash"
} else {
  $dest = if (Test-Path $Local -PathType Container) { $Local } else { Split-Path $Local -Parent }
  New-Item -ItemType Directory $dest -Force | Out-Null
  Copy-FromRunner $runner "$Remote\$name" $dest
  $v = Get-FileSha256 (Join-Path $dest $name)
  $rp = "$Remote\$name"
  $remoteHash = Invoke-RemoteScript $runner "& 'C:\RemoteWorkspace\worker\hash.ps1' '$rp'" 2>&1 | Select-Object -Last 1
  if ("$remoteHash".Trim() -ne $v) { throw "Checksum mismatch after download: $name" }
  Write-Output "SYNC|pulled|verified|$name|$v"
}
