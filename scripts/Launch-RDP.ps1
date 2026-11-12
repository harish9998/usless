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
  [switch]$Auto,
  [switch]$Ssh,
  [switch]$Desktop,
  [switch]$Status,
  [string[]]$Command,
  [int]$TimeoutSec = 900,
  # Catch-all so stray args (e.g. "rdp status extra") can never cause a
  # positional binding error, which hangs some hosts.
  [Parameter(ValueFromRemainingArguments = $true)]
  $Extra
)
$ErrorActionPreference = 'Stop'
if ($MyInvocation.InvocationName -eq '.') { throw 'Do not dot-source: execute it.' }

function Get-Card([int64]$RunId) {
  # gh writes "no valid artifacts" to STDERR while the runner is still booting.
  # With EAP=Stop that would kill the wait loop - so soften it locally.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $dir = Join-Path $env:TEMP "rdpcard-$RunId"
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
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
  } finally { $ErrorActionPreference = $prev }
}

# 1. Find or dispatch the run (-Auto: dispatch automatically when none live)
$runs = gh run list --repo $Repo --workflow $Workflow --limit 10 --json databaseId,status,createdAt | ConvertFrom-Json
$run = @($runs) | Where-Object { $_.status -ne 'completed' } | Select-Object -First 1
$doDispatch = $New -or $Auto
if (-not $run) {
  if ($doDispatch) {
    gh workflow run $Workflow --repo $Repo -f mode=rdp
    Write-Output 'DISPATCH|STATUS=SENT (no live run; booting fresh runner)'
    Start-Sleep -Seconds 20
    $runs = gh run list --repo $Repo --workflow $Workflow --limit 1 --json databaseId,status | ConvertFrom-Json
    $run = @($runs) | Select-Object -First 1
  } else {
    Write-Warning 'No active run. Use -New (or the rdp command, which auto-dispatches).'
    exit 1
  }
}
$runId = if ($run) { $run.databaseId } else { 0 }
Write-Output "RUN|id=$runId|status=$($run.status)"

# 2. Wait for the connection card artifact (IP + password)
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$card = $null
$waitStart = Get-Date
while ((Get-Date) -lt $deadline) {
  $card = Get-Card $runId
  if ($card -and $card['address']) { break }
  $waited = [int]((Get-Date) - $waitStart).TotalSeconds
  Write-Output ("WAIT|runner booting|elapsed={0}s" -f $waited)
  Start-Sleep -Seconds 20
}
if (-not $card -or -not $card['address']) { throw "No rdp-connection card after $TimeoutSec s (artifact = RDP ready beacon)" }
$ip, $user = $card['address'], $card['username']
if ($card['password']) { $Password = $card['password'] }
Write-Output "CARD|ip=$ip|user=$user|port=$($card['port'])"
$sshKey = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
$sshBase = @('-o','BatchMode=yes','-o','StrictHostKeyChecking=accept-new','-l', $user, $ip)
if (Test-Path $sshKey) { $sshBase = @('-o','BatchMode=yes','-o','StrictHostKeyChecking=accept-new','-i',$sshKey,'-l', $user, $ip) }

# --- rdp status: facts only, no terminal ---
if ($Status) {
  $age = '?'
  if ($run.createdAt) {
    try { $age = [int]([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse($run.createdAt)).TotalMinutes } catch { $age = '?' }
  }
  Write-Output "STATUS|run=$runId|ip=$ip|user=$user|age_min=$age"
  # Send as -EncodedCommand: immune to ssh/sshd quote-mangling.
  $script = @'
Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average | ForEach-Object { "CPU=" + [int]$_.Average + "%" }
Get-PSDrive C | ForEach-Object { "DISK_FREE_GB=" + [math]::Round($_.Free/1GB,1) }
Get-CimInstance Win32_OperatingSystem | ForEach-Object { "RAM_FREE_GB=" + [math]::Round($_.FreePhysicalMemory/1MB,1) + " RAM_TOTAL_GB=" + [math]::Round($_.TotalVisibleMemorySize/1MB,1) + " UP=" + ((Get-Date) - $_.LastBootUpTime).ToString("hh\:mm") }
'@
  $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  & ssh @sshBase ("powershell -NoProfile -EncodedCommand " + $b64)
  exit $LASTEXITCODE
}

# --- rdp cmd: one-off remote command, no terminal ---
if ($Command) {
  $remote = ($Command -join ' ')
  Write-Output "CMD|$ip|$remote"
  # Encoded so quotes/semicolons survive the ssh hop untouched.
  $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
  & ssh @sshBase ("powershell -NoProfile -EncodedCommand " + $b64)
  exit $LASTEXITCODE
}

# 3. Launch (terminal by default in -Ssh mode; mstsc otherwise)
if ($Ssh -and -not $Desktop) {
  # SSH mode: zero side effects - no registry, no cmdkey, no clipboard.
  Write-Output "CONNECT-SSH|ip=$ip|user=$user|OPENING-TERMINAL"
  Start-Process ssh -ArgumentList ($sshBase + @('-t')) -Wait:$false
  Write-Output "DONE|ssh|$ip"
  exit 0
}

# --- Desktop (mstsc) path: RDP-specific credential plumbing lives here only ---
$ok = (Test-NetConnection -ComputerName $ip -Port 3389 -WarningAction SilentlyContinue).TcpTestSucceeded
if (-not $ok) { throw "RDP port 3389 unreachable on $ip (tailnet/offline?)" }
# Store credentials so mstsc does NOT prompt (ephemeral machine, non-sensitive)
cmdkey /generic:TERMSRV/$ip /user:$user /pass:$Password | Out-Null
# Allow saved credentials in mstsc (HKLM needs elevation; best-effort)
try {
  reg add 'HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' /v DisablePasswordSaving /t REG_DWORD /d 0 /f | Out-Null
} catch { Write-Warning 'Could not set DisablePasswordSaving (not elevated) - prompt may still appear.' }

Set-Clipboard -Value $Password  # fallback: paste if mstsc still prompts
Write-Output "CONNECT|ip=$ip|user=$user|status=LAUNCHING"
Start-Process mstsc.exe -ArgumentList "/v:$ip /w:1280 /h:800"
Write-Output "DONE|desktop|$ip|password-on-clipboard=1"
