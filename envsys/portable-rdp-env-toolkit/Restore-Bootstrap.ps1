[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\persistent-environment.json",
    [string]$InstallScript = '',
    [string]$AutomationScript = ''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$workRoot = 'C:\Work'
if ([string]::IsNullOrWhiteSpace($InstallScript)) {
    $candidates = @(
        (Join-Path $workRoot 'Install-MyStack.ps1'),
        (Join-Path $workRoot 'scripts\Install-MyStack.ps1'),
        (Join-Path $PSScriptRoot 'Install-MyStack.ps1')
    )
    $InstallScript = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if ([string]::IsNullOrWhiteSpace($AutomationScript)) {
    $candidates = @(
        (Join-Path $workRoot 'Start-MyAutomation.ps1'),
        (Join-Path $workRoot 'scripts\Start-MyAutomation.ps1'),
        (Join-Path $PSScriptRoot 'Start-MyAutomation.ps1')
    )
    $AutomationScript = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}

Write-Output '[Bootstrap] 1/5 Restoring persistent user environment...'
& "$PSScriptRoot\Sync-PersistentEnvironment.ps1" -Mode Restore -ConfigPath $ConfigPath
if ($LASTEXITCODE -ne 0) { throw "Persistent environment restore failed." }

Write-Output '[Bootstrap] 2/5 Installing/verifying machine stack...'
if (Test-Path -LiteralPath $InstallScript) {
    & $InstallScript
    if ($LASTEXITCODE -ne 0) { throw "Install-MyStack.ps1 failed with exit code $LASTEXITCODE." }
} else { Write-Output '[Bootstrap] SKIP Install-MyStack.ps1 not found.' }

Write-Output '[Bootstrap] 3/5 Restoring environment once more after installs (safe/idempotent)...'
& "$PSScriptRoot\Sync-PersistentEnvironment.ps1" -Mode Restore -ConfigPath $ConfigPath
if ($LASTEXITCODE -ne 0) { throw "Post-install restore failed." }

Write-Output '[Bootstrap] 4/5 Starting automation...'
if (Test-Path -LiteralPath $AutomationScript) {
    & $AutomationScript
    if ($LASTEXITCODE -ne 0) { throw "Start-MyAutomation.ps1 failed with exit code $LASTEXITCODE." }
} else { Write-Output '[Bootstrap] SKIP Start-MyAutomation.ps1 not found.' }

Write-Output '[Bootstrap] 5/5 Persistent environment bootstrap COMPLETE.'
