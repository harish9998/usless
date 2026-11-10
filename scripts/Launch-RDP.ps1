#Requires -Version 5.1
# Launch-RDP.ps1 - zero-friction RDP: finds the live run, drops the connection
# card (IP + password), stores credentials, and opens mstsc with NO typing.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Launch-RDP.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Launch-RDP.ps1 -New
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Launch-RDP.ps1 -Password 'X' (override)
#
# Requires: gh CLI authed. Password comes from the run's rdp-connection
# artifact; fallback password only if the artifact lacks it.
param(
  [string]$Repo = 'harish9998/usless',
  [string]$Workflow = 'win 11 + tailscale + Download.bat script',
  [string]$Password = 'Runner@12345',
  [switch]$New,
  [int]$TimeoutSec = 900
)
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source: execute it.' }

function Get-Card([int64]$RunId) {
  $dir = Join-Path $env:TEMP "rdpcard-$RunId"
  gh run download $RunId --repo $Repo --name "rdp-connection-$RunId" --dir $dir 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { return $null }
  $card = Join-Path $dir 'rdp-connection.txt'
  if (-not (Test-Path $card)) { return $null }
  $map = @{}
  foreach ($line in Get-Content $card) {
    $k, $v = $line -split '=', 2
    if ($v) { $map[$k.Trim()] = $v.Trim() }
  }
  return $map
}

# 1. Find or dispatch the run
$run = gh run list --repo $Repo --workflow $Workflow --limit 10 --json databaseId,status |
  ConvertFrom-Json | Where-Object { $_.status -ne 'completed' } | Select-Object -First 1
if (-not $run) {
  if ($New) {
    gh workflow run $Workflow --repo $Repo -f mode=rdp
    Write-Output 'DISPATCH|STATUS=SENT'
    Start-Sleep -Seconds 20
    $run = gh run list --repo $Repo --workflow $Workflow --limit 1 --json databaseId,status | ConvertFrom-Json | Select-Object -First 1
  } else {
    Write-Warning 'No active run. Use -New to dispatch one.'
    exit 1
  }
}
$runId = if ($run) { $run.databaseId } else { 0 }
Write-Output "RUN|id=$runId|status=$($run.status)"

# 2. Wait for the connection card artifact (IP + password)
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$card = $null
while ((Get-Date) -lt $deadline) {
  $card = Get-Card $runId
  if ($card -and $card['address']) { break }
  Start-Sleep -Seconds 20
}
if (-not $card -or -not $card['address']) { throw "No rdp-connection card after $TimeoutSec s (artifact = RDP ready beacon)" }
$ip, $user = $card['address'], $card['username']
if ($card['password']) { $Password = $card['password'] }
Write-Output "CARD|ip=$ip|user=$user|port=$($card['port'])"

# 3. Reachability sanity check
$ok = (Test-NetConnection -ComputerName $ip -Port 3389 -WarningAction SilentlyContinue).TcpTestSucceeded
if (-not $ok) { throw "RDP port 3389 unreachable on $ip (tailnet/offline?)" }

# 4. Store credentials so mstsc does NOT prompt (ephemeral machine, non-sensitive)
cmdkey /generic:TERMSRV/$ip /user:$user /pass:$Password | Out-Null
# Allow saved credentials in mstsc (HKLM needs elevation; best-effort)
try {
  reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' /v DisablePasswordSaving /t REG_DWORD /d 0 /f | Out-Null
} catch { Write-Warning 'Could not set DisablePasswordSaving (not elevated) - prompt may still appear.' }

# 5. Clipboard fallback: password ready to paste if mstsc still prompts
Set-Clipboard -Value $Password

# 6. Launch
Write-Output "CONNECT|ip=$ip|user=$user|status=LAUNCHING"
Start-Process mstsc.exe -ArgumentList "/v:$ip /w:1280 /h:800"
Set-Clipboard -Value $Password  # keep on clipboard in case prompt appears
Write-Output "DONE|ip=$ip|user=$user|password-on-clipboard=1"
