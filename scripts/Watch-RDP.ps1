#Requires -Version 5.1
# Watch-RDP.ps1 - watches for machine rebirths and reconnects you automatically.
#
# The 6h runner dies and a successor is dispatched (when repo variable
# RDP_CHAIN = 'on'). This watcher polls the newest run every $PollSec seconds;
# when it sees a NEW run id, it launches the SSH terminal on the new box.
#
# Usage:
#   Watch-RDP.ps1              # watch until Ctrl+C (default 12 h)
#   Watch-RDP.ps1 -Once        # single poll (test)
#   Watch-RDP.ps1 -PollSec 60  # tighter polling
param(
  [string]$Repo = 'harish9998/usless',
  [string]$Workflow = 'win 11 + tailscale + Download.bat script',
  [string]$Launcher = (Join-Path $PSScriptRoot 'Launch-RDP.ps1'),
  [int]$PollSec = 90,
  [switch]$Once,
  [int]$MaxHours = 12
)
$ErrorActionPreference = 'Continue'
$deadline = (Get-Date).AddHours($MaxHours)

function Get-LiveRun {
  # gh stderr noise must never terminate the poll loop.
  try {
    $json = gh run list --repo $Repo --workflow $Workflow --limit 5 --json databaseId,status,createdAt 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $null }
    $runs = $json | ConvertFrom-Json
    return @($runs) | Where-Object { $_.status -ne 'completed' } | Select-Object -First 1
  } catch { return $null }
}

Write-Output "WATCH|start|repo=$Repo|poll=${PollSec}s|launcher=$Launcher"
$knownId = $null
$bootWait = $false
while ($true) {
  $run = Get-LiveRun
  $now = (Get-Date).ToUniversalTime().ToString('HH:mm:ss') + 'Z'

  if (-not $run) {
    Write-Output "WATCH|$now|NO-LIVE-RUN (chain off or between rebirths)"
    if ($bootWait) { $bootWait = $false; $knownId = $null }
  } elseif (-not $knownId) {
    $knownId = $run.databaseId
    Write-Output "WATCH|$now|LIVE run=$knownId (baseline)"
    $bootWait = $false
  } elseif ($run.databaseId -ne $knownId) {
    # NEW machine born -> hand the user to the new box.
    Write-Output "WATCH|$now|REBIRTH-DETECTED old=$knownId new=$($run.databaseId) -> connecting"
    $knownId = $run.databaseId
    Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $Launcher, '-Ssh')
    Write-Output "WATCH|$now|REBIRTH|TERMINAL-LAUNCHED (new machine)"
    $bootWait = $false
  } else {
    Write-Output "WATCH|$now|ok run=$knownId status=$($run.status)"
  }

  if ($Once) { Write-Output 'WATCH|once|DONE'; break }
  if ((Get-Date) -gt $deadline) { Write-Output 'WATCH|max-hours|EXIT'; break }
  Start-Sleep -Seconds $PollSec
}
