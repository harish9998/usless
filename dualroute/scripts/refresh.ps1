#Requires -Version 5.1
# refresh.ps1 - full refresh: discover -> resolve roles -> validate -> report.
param([string]$Root = "$env:USERPROFILE\usless\dualroute")
$ErrorActionPreference = 'Stop'
$regPath = "$Root\registry\catalog.json"
$backup = "$Root\registry\catalog.previous.json"
# Preserve last working config on failure
if (Test-Path $regPath) { Copy-Item $regPath $backup -Force }
try {
  & "$Root\scripts\discover.ps1" -Root $Root
  $cat = Get-Content $regPath -Raw | ConvertFrom-Json
  if ($cat.models.Count -lt 5) { throw 'suspiciously small catalog - refresh aborted' }
  $roles = $cat.roles.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }
  Write-Output ("REFRESH|OK|lastSuccessful=" + $cat.generatedAt)
  Write-Output ("REFRESH|roles=" + ($roles -join ';'))
} catch {
  if (Test-Path $backup) { Copy-Item $backup $regPath -Force; Write-Output "REFRESH|FAILED|previous-config-restored|$($_.Exception.Message)" }
  else { throw }
}
