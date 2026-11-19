#Requires -Version 5.1
# pc-offload.ps1 - offload heavy audio/render work FROM RUNNER TO PC
# (runner has no GPU / limited CPU; PC has RTX 3050 + Blender + ffmpeg).
# Uses the PC-agent bridge (pc.ps1 full key) over Tailscale, no Cloudflare.
param(
  [Parameter(Mandatory=$true)][string]$Command,   # PowerShell command to run ON PC
  [string[]]$InputFiles = @(),                   # runner files to upload to PC first
  [string[]]$OutputPatterns = @(),               # PC-side filenames to download back
  [string]$PcWorkDir = "C:\Work\rdp-jobs\job-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)
$ErrorActionPreference = 'Stop'
$pc = 'C:\Work\pc.ps1'
$get = 'C:\Work\pc-get.ps1'
$send = 'C:\Work\pc-send.ps1'
if (-not (Test-Path $pc)) { throw "PC bridge missing: $pc (run Restore-AICredentials)" }
# Prepare PC work dir
& powershell -NoProfile -ExecutionPolicy Bypass -File $pc "New-Item -ItemType Directory '$PcWorkDir' -Force | Out-Null" | Out-Null
# Upload inputs (pc-send targets inbox; use full-key scp to exact dir instead)
$key = Join-Path $env:USERPROFILE '.ssh\pc-agent-ed25519'
$ipCard = Join-Path $env:TEMP 'pc-addr.txt'
foreach ($f in $InputFiles) {
  if (-not (Test-Path $f)) { Write-Warning "Input missing: $f"; continue }
  & scp -o StrictHostKeyChecking=accept-new -i $key -r $f "harishjaswal@100.111.187.124:$PcWorkDir/" | Out-Null
  Write-Output "UPLOADED|$(Split-Path $f -Leaf) -> PC:$PcWorkDir"
}
# Run command on PC, in PC work dir, encoded (quote-safe)
$script = "Set-Location '$PcWorkDir'; $Command"
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
& powershell -NoProfile -ExecutionPolicy Bypass -File $pc "powershell -NoProfile -EncodedCommand $b64"
$code = $LASTEXITCODE
Write-Output "RUN|exit=$code"
# Download results back to runner C:\Work\offload-results
$local = 'C:\Work\offload-results'; New-Item -ItemType Directory $local -Force | Out-Null
foreach ($pattern in $OutputPatterns) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $pc "Get-ChildItem '$PcWorkDir' -Filter '$pattern' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name" 2>$null | ForEach-Object {
    $name = $_.Trim()
    if ($name) {
      & scp -o StrictHostKeyChecking=accept-new -i $key "harishjaswal@100.111.187.124:$PcWorkDir/$name" $local | Out-Null
      Write-Output "DOWNLOADED|$name -> $local"
    }
  }
}
exit $code
