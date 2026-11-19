#Requires -Version 5.1
# rdp-offload.ps1 - offload heavy audio/render work FROM PC TO runner
# (use when PC is busy or when you want the runner's free CPU/RAM for processing).
# For the opposite direction (runner -> PC), use C:\Work\pc-offload.ps1 on the runner.
param(
  [Parameter(Mandatory=$true)][string]$Command,   # command to run on runner (PowerShell)
  [string]$Target = '1',                          # runner index or run id
  [string[]]$InputFiles = @(),                    # local files to upload to runner first
  [string[]]$OutputPatterns = @(),                # remote paths/globs to download back
  [string]$WorkDir = "C:\Work\offload-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
  [string]$Repo = "$env:USERPROFILE\usless"
)
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $Repo 'scripts\Launch-RDP.ps1'
$key = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
$flags = if ($Target -match '^\d{7,}$') { @('-Id', $Target) } else { @('-Index', $Target) }
$raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher @flags -PrintIp 2>$null
$line = @($raw | Where-Object { "$_" -like 'IP|*' } | Select-Object -Last 1)[0]
if (-not $line) { throw "Cannot resolve runner '$Target'" }
$ip, $runId, $user = ($line -split '\|')[1..3]
Write-Output "OFFLOAD|run=$runId|ip=$ip|workdir=$WorkDir"
$sshBase = @('-o','StrictHostKeyChecking=accept-new','-o','ConnectTimeout=20','-i',$key,'-l',$user,$ip)
# Prepare remote work dir
& ssh @sshBase "New-Item -ItemType Directory '$WorkDir' -Force | Out-Null" | Out-Null
# Upload inputs
foreach ($f in $InputFiles) {
  if (-not (Test-Path $f)) { Write-Warning "Input missing: $f"; continue }
  & scp -o StrictHostKeyChecking=accept-new -i $key -r $f "${user}@${ip}:$WorkDir/" | Out-Null
  Write-Output "UPLOADED|$(Split-Path $f -Leaf)"
}
# Build a remote script with the user's command, encoded (quote-safe), run it
$script = "Set-Location '$WorkDir'; $Command"
$b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
& ssh @sshBase "powershell -NoProfile -EncodedCommand $b64"
$code = $LASTEXITCODE
Write-Output "RUN|exit=$code"
# Download outputs
foreach ($pattern in $OutputPatterns) {
  & ssh @sshBase "Get-ChildItem '$WorkDir' -Filter '$pattern' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name" 2>$null | ForEach-Object {
    $name = $_.Trim()
    if ($name) {
      $localDir = Join-Path $env:USERPROFILE 'Downloads\RDP-Inbox'
      New-Item -ItemType Directory $localDir -Force | Out-Null
      & scp -o StrictHostKeyChecking=accept-new -i $key "${user}@${ip}:$WorkDir/$name" $localDir | Out-Null
      Write-Output "DOWNLOADED|$name -> $localDir"
    }
  }
}
exit $code
