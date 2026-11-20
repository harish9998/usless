#Requires -Version 5.1
# omni-tunnel.ps1 - expose OmniRoute (localhost:20128) to the internet via Cloudflare quick tunnel.
# Uses a Windows Scheduled Task so the tunnel survives the SSH session.
# Usage: omni-tunnel.ps1          start + print URL
#        omni-tunnel.ps1 -Url     print current URL
#        omni-tunnel.ps1 -Stop    stop tunnel
param([switch]$Stop, [switch]$Url, [int]$Port = 20128)
$ErrorActionPreference = 'SilentlyContinue'
$urlFile = 'C:\Work\omni-url.txt'
$logFile = 'C:\Work\omni-tunnel.log'
$taskName = 'OmniRoute-Tunnel'

$cf = @(
  (Get-Command cloudflared -ErrorAction SilentlyContinue).Source,
  "$env:LOCALAPPDATA\Microsoft\WinGet\Links\cloudflared.exe",
  'C:\ProgramData\chocolatey\bin\cloudflared.exe',
  'C:\ProgramFiles\cloudflared\cloudflared.exe'
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

function Get-Url {
  $u = $null
  if (Test-Path $urlFile) { $u = (Get-Content $urlFile -Raw).Trim() }
  if (-not $u -and (Test-Path $logFile)) {
    try {
      $fs = [IO.File]::Open($logFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
      $sr = New-Object IO.StreamReader($fs)
      $a = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
      $mm = [regex]::Match($a, 'https://[a-z0-9-]+\.trycloudflare\.com')
      if ($mm.Success) { $u = $mm.Value; [IO.File]::WriteAllText($urlFile, $u) }
    } catch { }
  }
  return $u
}
function Find-Cf {
  $c = @(
    (Get-Command cloudflared -ErrorAction SilentlyContinue).Source,
    "$env:LOCALAPPDATA\Microsoft\WinGet\Links\cloudflared.exe",
    'C:\ProgramData\chocolatey\bin\cloudflared.exe',
    'C:\ProgramFiles\cloudflared\cloudflared.exe'
  ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  return $c
}

if ($Stop) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "name='cloudflared.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-Item $urlFile -Force -ErrorAction SilentlyContinue
  Write-Output 'TUNNEL|STOPPED'; exit 0
}
if ($Url) {
  $u = $null
  if (Test-Path $logFile) {
    try {
      $fs = [IO.File]::Open($logFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
      $sr = New-Object IO.StreamReader($fs)
      $a = $sr.ReadToEnd(); $sr.Close(); $fs.Close()
      $mm = [regex]::Match($a, 'https://[a-z0-9-]+\.trycloudflare\.com')
      if ($mm.Success) { $u = $mm.Value; [IO.File]::WriteAllText($urlFile, $u) }
    } catch { }
  }
  if (-not $u -and (Test-Path $urlFile)) { $u = (Get-Content $urlFile -Raw).Trim() }
  if ($u) { Write-Output "TUNNEL|URL=$u" } else { Write-Output 'TUNNEL|NO-URL (start tunnel first)' }
  exit 0
}

$cf = Find-Cf
if (-not $cf) {
  Write-Output 'Installing cloudflared via choco...'
  $choco = 'C:\ProgramData\chocolatey\bin\choco.exe'
  if (Test-Path $choco) { & $choco install cloudflared -y --no-progress 2>&1 | Select-Object -Last 2 }
  $cf = Find-Cf
  if (-not $cf) { throw 'cloudflared not found after install' }
}
# Ensure OmniRoute listening
if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
  Write-Output "OMNI|starting OmniRoute on $Port..."
  Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command','omniroute') -WindowStyle Hidden
  for ($i=0; $i -lt 45; $i++) { Start-Sleep 2; if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { break } }
  if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) { throw 'OmniRoute failed to start' }
}
# Register scheduled task (persists beyond SSH session)
Remove-Item $logFile -Force -ErrorAction SilentlyContinue
Remove-Item $urlFile -Force -ErrorAction SilentlyContinue
# Wrapper batch captures stderr to log so -Url can parse it
$wrapper = 'C:\Work\omni-tunnel-run.cmd'
"@echo off`r`n`"$cf`" tunnel --url http://localhost:$Port --no-autoupdate 2>`"$logFile`"" | Set-Content $wrapper -Encoding ASCII
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
# Launch detached via WMI (survives SSH session end, unlike Start-Process)
Get-CimInstance Win32_Process -Filter "name='cloudflared.exe'" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$wrapper = 'C:\Work\omni-tunnel-run.cmd'
"@echo off`r`n`"$cf`" tunnel --url http://localhost:$Port --no-autoupdate 2>`"$logFile`"" | Set-Content $wrapper -Encoding ASCII
$cmd = "cmd.exe /c `"$wrapper`""
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
Write-Output "TUNNEL|pid=$($r.ProcessId)|rc=$($r.ReturnValue)"
# Poll for URL
$u = $null
for ($i=0; $i -lt 60; $i++) {
  Start-Sleep 1
  $u = Get-Url
  if ($u) { break }
}
if ($u) {
  Write-Output "TUNNEL|URL=$u"
  Write-Output "TUNNEL|API=$u/v1"
} else {
  Write-Output 'TUNNEL|URL-PENDING (run: omni-tunnel.ps1 -Url)'
  if (Test-Path $logFile) { Get-Content $logFile -Tail 3 }
}
