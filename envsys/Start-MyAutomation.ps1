#Requires -Version 5.1
# Start-MyAutomation.ps1 - lives in C:\Work. One command starts the whole environment.
# Called by Install-MyStack.ps1 on every boot AND usable manually after RDP login.
# Health-gated: prints OK/FAIL per subsystem, exits nonzero on failure.
param([string]$WorkDir = 'C:\Work')
$ErrorActionPreference = 'SilentlyContinue'
function Write-Step { param([string]$m) Write-Host "==> $m" }
$fail = 0
function Check([string]$n, [bool]$ok) {
  Write-Host ($n + ': ' + ($(if ($ok) { 'OK' } else { 'FAIL' })))
  if (-not $ok) { $script:fail++ }
}

Write-Step 'Docker'
$hasDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)
Check 'Docker' $hasDocker
if ($hasDocker) {
  $comps = docker ps --format '{{.Names}}' 2>$null
  Write-Host ('containers: ' + ($(if ($comps) { ($comps -join ', ') } else { '(none)' })))
}

Write-Step 'OpenClaw (config restored from snapshot; first boot = SKIP, not FAIL)'
$ocDir = Join-Path $WorkDir 'openclaw'
$ocCfg = Test-Path (Join-Path $ocDir 'config')
if (-not $ocCfg) {
  Write-Host 'OpenClaw config: SKIP (put openclaw\config in C:\Work once, it persists via snapshots)'
} else {
  Check 'OpenClaw config (restored)' $true
  $ocProc = Get-Process -Name 'node' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like '*openclaw*' }
  if (-not $ocProc) {
    Write-Host 'Starting OpenClaw...'
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"Set-Location '$ocDir'; npx openclaw run`"" -WindowStyle Minimized
    Start-Sleep -Seconds 10
  }
  Check 'OpenClaw process' ([bool](Get-Process -Name 'node' -ErrorAction SilentlyContinue))
}

Write-Step 'Workspace + persistence chain'
Check 'Workspace' (Test-Path $WorkDir)
Check 'Heartbeat writable' ([bool](New-Item -ItemType Directory -Path (Join-Path $WorkDir 'heartbeat') -Force -ErrorAction SilentlyContinue))

if ($fail -gt 0) { Write-Warning "AUTOMATION DEGRADED ($fail). See lines above."; exit 1 }
Write-Host 'AUTOMATION UP.'
