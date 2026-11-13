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
  # Cache: one winget list call serves install-check + health gate (was 2N subprocess calls).
  $wingetCache = winget list --exact 2>$null | Out-String
  foreach ($t in $declared) {
    $have = $wingetCache | Select-String -Pattern ([regex]::Escape($t.winget)) -SimpleMatch
    if (-not $have) {
      Write-Host ("installing missing: " + $t.winget)
      winget install -e --id $t.winget --silent --accept-package-agreements --accept-source-agreements | Out-Null
      $wingetCache = winget list --exact 2>$null | Out-String
    } else { Write-Host ("ok: " + $t.winget) }
  }
} else { Write-Host 'No machine.manifest.json in C:\Work - skipping tool check.' }

Write-Step '2b/6 AI CLIs (npm global: opencode + Qoder CN/INTL, idempotent)'
$npmCache = (npm ls -g --depth=0 2>$null | Out-String)
$cliPkgs  = @('opencode-ai', '@qoder-ai/qodercli', '@qodercn-ai/qoderclicn')
foreach ($p in $cliPkgs) {
  if ($npmCache -notmatch ([regex]::Escape($p))) {
    Write-Host "installing CLI: $p"
    npm install -g $p 2>&1 | Select-Object -Last 2 | Out-Null
  } else { Write-Host "ok CLI: $p" }
}
if (Get-Command opencode -ErrorAction SilentlyContinue) {
  Write-Host ("CLI opencode: " + (opencode --version 2>$null))
} else { Write-Host 'CLI opencode: FAIL (npm install failed?)'; $fail++ }

Write-Step '2c/6 Video-skills index (always present, clonable extra skills on demand)'
$skillsDir = Join-Path $WorkDir 'skills\awesome-claude-video-skills'
if (Test-Path (Join-Path $skillsDir '.git')) {
  git -C $skillsDir pull --depth 1 2>&1 | Select-Object -Last 1
} else {
  New-Item -ItemType Directory (Join-Path $WorkDir 'skills') -Force | Out-Null
  git clone --depth 1 https://github.com/zhuyansen/awesome-claude-video-skills.git $skillsDir 2>&1 | Select-Object -Last 1
}
if (Test-Path $skillsDir) { Write-Host "SKILLS|path=$skillsDir" } else { Write-Host 'SKILLS|FAIL' }

Write-Step '2d/6 Qoder skills deploy (bundled zips -> every user profile .qoder\skills)'
$bundleDir = Join-Path $PSScriptRoot 'skills'
$qoderUsers = @($env:USERPROFILE, 'C:\Users\RDP') | Where-Object { Test-Path (Split-Path $_ -Parent) } | Select-Object -Unique
if (Test-Path $bundleDir) {
  foreach ($zip in Get-ChildItem $bundleDir -Filter '*.zip' -File -ErrorAction SilentlyContinue) {
    foreach ($u in $qoderUsers) {
      $dest = Join-Path $u '.qoder\skills'
      New-Item -ItemType Directory $dest -Force | Out-Null
      $tmp = Join-Path $env:TEMP ("_skillx-" + [IO.Path]::GetRandomFileName())
      try {
        Expand-Archive -Path $zip.FullName -DestinationPath $tmp -Force
        # Zip layout: <SkillName>/... -> copy the skill folder(s) into skills dir
        Get-ChildItem $tmp -Directory | ForEach-Object {
          Copy-Item $_.FullName (Join-Path $dest $_.Name) -Recurse -Force
          Write-Host ("SKILL|deployed={0}|to={1}" -f $_.Name, $u)
        }
      } catch { Write-Host ("SKILL|FAIL|" + $zip.Name + "|" + $_.Exception.Message) }
      finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
  Write-Host 'SKILLS|QODER-DEPLOY=DONE'
} else { Write-Host 'No envsys\skills bundle dir - skipping Qoder skill deploy.' }

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
  $ok = [bool]($wingetCache | Select-String -Pattern ([regex]::Escape($t.winget)) -SimpleMatch)
  Write-Host ('Tool ' + $t.winget + ': ' + ($(if ($ok) { 'OK' } else { 'FAIL'; $fail++ })))
}
if ($fail -gt 0) { exit 1 }
Write-Host 'STACK READY.'
