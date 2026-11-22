#Requires -Version 5.1
# rdp-peer.ps1 - direct PC <-> runner SSH file transfer (no Cloudflare).
# Uses the same SSH key (id_ed25519) baked into runners; resolves runner by
# index (1=newest live) or run id via Launch-RDP.ps1 -PrintIp.
param(
  [Parameter(Mandatory=$true)][ValidateSet('shell','send','get','exec')][string]$Action,
  [string]$Target = '1',       # index (1=newest) or run id (e.g. 44512751010)
  [string]$Local,              # send: local file/dir on PC; get: local destination
  [string]$Remote = 'C:/Work/', # send: remote dir; get: remote file/dir on runner
  [string]$Command,            # exec: command to run on runner
  [string]$Repo = "$env:USERPROFILE\usless"
)
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $Repo 'scripts\Launch-RDP.ps1'
$key = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
if (-not (Test-Path $key)) { $key = 'C:\Users\RDP\.ssh\id_ed25519' }
# Resolve IP via -List then -Id (PS5.1 -File + -Index splatting is unreliable)
$listRaw = & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -List 2>$null
$listLines = @($listRaw | Where-Object { "$_" -like 'LIST|[[]*' })
if ($Target -match '^\d{7,}$') { $chosen = @($listRaw | Where-Object { "$_" -match "run=$Target " } | Select-Object -Last 1)[0]; if (-not $chosen) { $chosen = $listLines[0] } }
else { $idx = [int]$Target; $chosen = if ($idx -ge 1 -and $idx -le $listLines.Count) { $listLines[$idx-1] } else { $listLines[0] } }
if (-not $chosen -or $chosen -notmatch 'run=(\d+)') { throw "No live runner (use: rdp list)" }
$rid = [regex]::Match($chosen, 'run=(\d+)').Groups[1].Value
$raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -Id $rid -PrintIp 2>$null
$line = @($raw | Where-Object { "$_" -like 'IP|*' } | Select-Object -Last 1)[0]
if (-not $line) { throw "Could not resolve runner '$Target' IP (is it live? use: rdp list)" }
$ip, $runId, $user = ($line -split '\|')[1..3]
Write-Output "PEER|run=$runId|ip=$ip|user=$user|action=$Action"
$sshBase = @('-o','StrictHostKeyChecking=accept-new','-o','ConnectTimeout=20','-i',$key,'-l',$user,$ip)
switch ($Action) {
  'shell' { & ssh @sshBase; exit $LASTEXITCODE }
  'exec'  { & ssh @sshBase $Command; exit $LASTEXITCODE }
  'send'  {
    if (-not $Local) { throw 'send: -Local <file or folder>' }
    & scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -i $key -r $Local "${user}@${ip}:$Remote"
    exit $LASTEXITCODE
  }
  'get'   {
    if (-not $Remote) { throw 'get: -Remote <path on runner>' }
    $dest = if ($Local) { $Local } else { "$env:USERPROFILE\Downloads\RDP-Inbox" }
    New-Item -ItemType Directory $dest -Force | Out-Null
    & scp -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -i $key -r "${user}@${ip}:$Remote" $dest
    exit $LASTEXITCODE
  }
}
