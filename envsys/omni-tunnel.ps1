#Requires -Version 5.1
# omni-tunnel.ps1 - expose OmniRoute (localhost:20128) to the internet via Cloudflare Tunnel.
# No account needed (quick tunnel). Start OmniRoute first if not running.
# Usage on runner:
#   powershell -File C:\Work\omni-tunnel.ps1            # start tunnel, print URL
#   powershell -File C:\Work\omni-tunnel.ps1 -Stop      # stop tunnel
#   powershell -File C:\Work\omni-tunnel.ps1 -Url       # print current URL
param([switch]$Stop, [switch]$Url, [int]$Port = 20128)
$ErrorActionPreference = 'SilentlyContinue'
$urlFile = 'C:\Work\omni-url.txt'
$logFile = 'C:\Work\omni-tunnel.log'

# Find cloudflared (winget/scoop/choco locations)
$cf = @(
  (Get-Command cloudflared -ErrorAction SilentlyContinue).Source,
  "$env:LOCALAPPDATA\Microsoft\WinGet\Links\cloudflared.exe",
  'C:\ProgramData\chocolatey\bin\cloudflared.exe',
  'C:\Work\cloudflared.exe'
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($Stop) {
  Get-CimInstance Win32_Process -Filter "name='cloudflared.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-Item $urlFile -Force -ErrorAction SilentlyContinue
  Write-Output 'TUNNEL|STOPPED'
  exit 0
}
if ($Url) {
  if (Test-Path $urlFile) { Write-Output ("TUNNEL|URL=" + (Get-Content $urlFile -Raw).Trim()) }
  else { Write-Output 'TUNNEL|NO-URL (start tunnel first)' }
  exit 0
}
if (-not $cf) {
  Write-Output 'Installing cloudflared via choco...'
  $choco = 'C:\ProgramData\chocolatey\bin\choco.exe'
  if (Test-Path $choco) { & $choco install cloudflared -y --no-progress 2>&1 | Select-Object -Last 2 }
  $cf = "$env:LOCALAPPDATA\Microsoft\WinGet\Links\cloudflared.exe"
  if (-not (Test-Path $cf)) { $cf = 'C:\ProgramData\chocolatey\bin\cloudflared.exe' }
  if (-not (Test-Path $cf)) { throw 'cloudflared not found after install' }
}
# Ensure OmniRoute is running on $Port
$listen = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if (-not $listen) {
  Write-Output "OMNI|not listening on $Port - starting OmniRoute..."
  Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',"omniroute") -WindowStyle Hidden
  for ($i=0; $i -lt 30; $i++) { Start-Sleep 2; if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { break } }
  if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) { throw 'OmniRoute failed to start' }
}
# Start cloudflared tunnel (logs stderr where URL appears)
if (Get-CimInstance Win32_Process -Filter "name='cloudflared.exe'") { Write-Output 'TUNNEL|already running' }
else {
  Start-Process -FilePath $cf -ArgumentList @('tunnel','--url',"http://localhost:$Port","--no-autoupdate") -RedirectStandardError $logFile -WindowStyle Hidden
}
# Poll log for URL (up to ~40s)
$url = $null
for ($i=0; $i -lt 40; $i++) {
  Start-Sleep 1
  if (Test-Path $logFile) {
    $m = Select-String -Path $logFile -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' | Select-Object -Last 1
    if ($m) { $url = $m.Matches[0].Value; break }
  }
}
if ($url) {
  [IO.File]::WriteAllText($urlFile, $url)
  Write-Output "TUNNEL|URL=$url"
  Write-Output "TUNNEL|DASHBOARD=$url"
  Write-Output "TUNNEL|API=$url/v1"
} else {
  Write-Output 'TUNNEL|URL-NOT-YET (check log)'
  if (Test-Path $logFile) { Get-Content $logFile -Tail 5 }
}
