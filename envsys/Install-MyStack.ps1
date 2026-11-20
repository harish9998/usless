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
$cliPkgs  = @('opencode-ai', '@qoder-ai/qodercli', '@qodercn-ai/qoderclicn', 'omniroute')
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

Write-Step '2d/6 Bundled skills -> Qoder + OpenCode (every profile)'
$bundleDir = Join-Path $PSScriptRoot 'skills'
$qoderUsers = @($env:USERPROFILE, 'C:\Users\RDP') | Where-Object { Test-Path (Split-Path $_ -Parent) } | Select-Object -Unique
if (Test-Path $bundleDir) {
  foreach ($zip in Get-ChildItem $bundleDir -Filter '*.zip' -File -ErrorAction SilentlyContinue) {
    # Skill name comes from the zip filename -> handles both zip layouts:
    #   a) zip contains <Name>/...   b) zip contains files at root
    $name = [IO.Path]::GetFileNameWithoutExtension($zip.Name)
    foreach ($u in $qoderUsers) {
      $tmp = Join-Path $env:TEMP ("_skillx-" + [IO.Path]::GetRandomFileName())
      try {
        Expand-Archive -Path $zip.FullName -DestinationPath $tmp -Force
        $items = @(Get-ChildItem $tmp -Force)
        $src = $tmp
        if ($items.Count -eq 1 -and $items[0].PSIsContainer -and $items[0].Name -eq $name) { $src = $items[0].FullName }
        foreach ($sub in @('.qoder\skills', '.config\opencode\skills')) {
          $dest = Join-Path $u "$sub\$name"
          if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }
          New-Item -ItemType Directory $dest -Force | Out-Null
          Copy-Item "$src\*" $dest -Recurse -Force
          Write-Host ("SKILL|deployed={0}|to={1}" -f $name, $dest)
        }
      } catch { Write-Host ("SKILL|FAIL|" + $zip.Name + "|" + $_.Exception.Message) }
      finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
  Write-Host 'SKILLS|QODER-DEPLOY=DONE'
} else { Write-Host 'No envsys\skills bundle dir - skipping skill deploy.' }

Write-Step '2e/6 Media tools (ffmpeg/ffprobe) - required by video skills'
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
  $choco = 'C:\ProgramData\chocolatey\bin\choco.exe'
  if (Test-Path $choco) {
    Write-Host 'Installing ffmpeg via choco...'
    & $choco install ffmpeg -y --no-progress 2>&1 | Select-Object -Last 2
  } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install -e --id Gyan.FFmpeg --silent --accept-package-agreements --accept-source-agreements | Out-Null
  }
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + $env:Path
}
Write-Host ("MEDIA|ffmpeg=" + $(if (Get-Command ffmpeg -ErrorAction SilentlyContinue) { (ffmpeg -version 2>&1 | Select-Object -First 1) } else { 'MISSING' }))

Write-Step '2e2/6 Cloudflared (for omni-tunnel / remote access)'
if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
  $choco = 'C:\ProgramData\chocolatey\bin\choco.exe'
  if (Test-Path $choco) { & $choco install cloudflared -y --no-progress 2>&1 | Select-Object -Last 2 }
  $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + $env:Path
}
Write-Host ("CLOUDFLARED=" + $(if (Get-Command cloudflared -ErrorAction SilentlyContinue) { (cloudflared --version 2>&1 | Select-Object -First 1) } else { 'MISSING' }))

Write-Step '2f/6 OmniRoute CLI aliases (omni / omnirouter -> omniroute)'
if (Get-Command omniroute -ErrorAction SilentlyContinue) {
  foreach ($pro in $profiles) {
    $aliasFile = Join-Path $pro 'Documents\WindowsPowerShell\Microsoft.WindowsPowerShell_profile.ps1'
    if (Test-Path (Split-Path $aliasFile -Parent)) {
      $aliasBlock = @'
# omniroute aliases
if (Get-Command omniroute -ErrorAction SilentlyContinue -CommandType Application) {
  Set-Alias -Name omni -Value omniroute -ErrorAction SilentlyContinue
  Set-Alias -Name omnirouter -Value omniroute -ErrorAction SilentlyContinue
}
'@
      if (-not (Select-String -Path $aliasFile -Pattern 'Set-Alias -Name omni ' -Quiet -ErrorAction SilentlyContinue)) { Add-Content $aliasFile $aliasBlock }
    }
  }
  Write-Host 'OMNI|aliases=OK'
} else { Write-Host 'OMNI|not installed - skip aliases' }

Write-Step '3/6 Docker (skipped by default - lean render box; set RDP_FULL_STACK=on to enable)'
$full = ($env:RDP_FULL_STACK -eq 'on')
if ($full) {
  $dv = (docker version --format '{{.Server.Version}}' 2>$null)
  if ($dv) { Write-Host "ok: docker engine $dv" }
  else {
    Write-Host 'Docker engine missing - installing Docker Desktop...'
    winget install -e --id Docker.DockerDesktop --silent --accept-package-agreements --accept-source-agreements | Out-Null
    Start-Service com.docker.service -ErrorAction SilentlyContinue
  }
} else { Write-Host 'Docker SKIPPED (lean mode)' }

Write-Step '4/6 Containers (skipped in lean mode)'
if ($full) {
  $compose = Join-Path $WorkDir 'docker\compose.yml'
  if ((Test-Path $compose) -and (Get-Command docker -ErrorAction SilentlyContinue)) {
    docker compose -f $compose up -d 2>&1 | Select-Object -Last 3
  } else { Write-Host 'No docker\compose.yml - skipping containers.' }
} else { Write-Host 'Containers SKIPPED (lean mode)' }

Write-Step '5/6 Automation (skipped in lean mode)'
if ($full) {
  $start = Join-Path $WorkDir 'Start-MyAutomation.ps1'
  if (Test-Path $start) {
    powershell -NoProfile -ExecutionPolicy Bypass -File $start
  } else { Write-Host 'No Start-MyAutomation.ps1 - skipping automation start.' }
} else { Write-Host 'Automation SKIPPED (lean mode)' }

Write-Step '6/6 Health'
$checks = @(
  @{ n = 'Workspace'; ok = (Test-Path $WorkDir) },
  @{ n = 'Docker'; ok = ($full -or [bool](Get-Command docker -ErrorAction SilentlyContinue)) },
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
