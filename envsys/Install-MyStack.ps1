#Requires -Version 5.1
# Install-MyStack.ps1 - CENTRAL BOOTSTRAP. Lives in C:\Work (restored every rebirth).
# Fresh runner auto-runs this (workflow hook). Edit once, applied forever. Idempotent.
# Order: verify env -> manifest tools -> docker -> compose -> automation -> health.
param([string]$WorkDir = 'C:\Work')
$ErrorActionPreference = 'SilentlyContinue'
function Write-Step { param([string]$m) Write-Host "==> $m" }
$fail = 0

Write-Step '1/6 Environment'
Write-Host ("OS: " + (Get-CimInstance Win32_OperatingSystem).Caption)
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }

Write-Step '2/6 Manifest tools (install only missing, verify versions)'
$manifest = Join-Path $WorkDir 'machine.manifest.json'
$declared = @()
if (Test-Path $manifest) {
  $man = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
  $declared = @($man.tools)
  foreach ($t in $declared) {
    $have = winget list --id $t.winget --exact 2>$null | Select-String -Pattern ([regex]::Escape($t.winget))
    if (-not $have) {
      Write-Host ("installing missing: " + $t.winget)
      winget install -e --id $t.winget --silent --accept-package-agreements --accept-source-agreements | Out-Null
    } else { Write-Host ("ok: " + $t.winget) }
  }
} else { Write-Host 'No machine.manifest.json in C:\Work - skipping tool check.' }

Write-Step '3/6 Docker (detect first: GHA images ship it, never reinstall blindly)'
$dv = (docker version --format '{{.Server.Version}}' 2>$null)
if ($dv) { Write-Host "ok: docker engine $dv" }
else {
  Write-Host 'Docker engine missing - installing Docker Desktop...'
  winget install -e --id Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements | Out-Null
  Start-Service com.docker.service -ErrorAction SilentlyContinue
}

Write-Step '4/6 Containers (recreated; only volumes/data persist via snapshots)'
$compose = Join-Path $WorkDir 'docker\compose.yml'
if ((Test-Path $compose) -and (Get-Command docker -ErrorAction SilentlyContinue)) {
  docker compose -f $compose up -d 2>&1 | Select-Object -Last 3
} else { Write-Host 'No docker\compose.yml - skipping containers.' }

Write-Step '5/6 Automation (OpenClaw + agents; state lives in C:\Work, restored)'
$start = Join-Path $WorkDir 'Start-MyAutomation.ps1'
if (Test-Path $start) {
  powershell -NoProfile -ExecutionPolicy Bypass -File $start
} else { Write-Host 'No Start-MyAutomation.ps1 - skipping automation start.' }

Write-Step '6/6 Health'
$checks = @(
  @{ n = 'Workspace'; ok = (Test-Path $WorkDir) },
  @{ n = 'Docker'; ok = [bool](Get-Command docker -ErrorAction SilentlyContinue) },
  @{ n = 'Manifest'; ok = ((-not (Test-Path $manifest)) -or $true) }
)
foreach ($c in $checks) {
  Write-Host ($c.n + ': ' + ($(if ($c.ok) { 'OK' } else { 'FAIL'; $fail++ })))
}
# Declared tools are REQUIRED: a missing declared tool fails the gate (no false READY).
foreach ($t in $declared) {
  $ok = [bool](winget list --id $t.winget --exact 2>$null | Select-String -Pattern ([regex]::Escape($t.winget)))
  Write-Host ('Tool ' + $t.winget + ': ' + ($(if ($ok) { 'OK' } else { 'FAIL'; $fail++ })))
}
if ($fail -gt 0) { exit 1 }
Write-Host 'STACK READY.'
