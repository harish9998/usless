[CmdletBinding()]
param([string]$ConfigPath = "$PSScriptRoot\persistent-environment.json")
$ErrorActionPreference='Stop'
Write-Output '[FirstSetup] Capture the current user environment into C:\Work\PersistentEnvironment.'
Write-Output '[FirstSetup] Run this AFTER you finish the one-time setup on a live runner.'
& "$PSScriptRoot\Sync-PersistentEnvironment.ps1" -Mode Capture -ConfigPath $ConfigPath
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Output '[FirstSetup] Next: let your normal Snapshot-VPSWork.ps1 snapshot C:\Work.'
