[CmdletBinding()]
param(
    [string]$ToolkitRoot = 'C:\Work',
    [switch]$CaptureCurrent
)
$ErrorActionPreference='Stop'
$source = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $ToolkitRoot 'PersistentEnvironmentToolkit'
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
Write-Output "[Installer] Toolkit copied to $target"
if ($CaptureCurrent) {
    & (Join-Path $target 'Sync-PersistentEnvironment.ps1') -Mode Capture
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
Write-Output '[Installer] DONE'
