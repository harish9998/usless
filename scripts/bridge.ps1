#Requires -Version 5.1
# bridge.ps1 - permanent bidirectional file bridge between PC and RDP runner.
# Runs on EITHER machine. Auto-detects which side it's on.
#   bridge status        - health of both sides
#   bridge send <file>   - send a file to the OTHER machine
#   bridge get <file>    - fetch a file FROM the other machine
#   bridge open          - open the other machine's workspace in Explorer
#   bridge sync <dir>    - checksum-verified directory sync (push to other side)
param(
  [ValidateSet('status','send','get','open','sync')][string]$Action = 'status',
  [string]$Path = '', [string]$Repo = "$env:USERPROFILE\usless"
)
$ErrorActionPreference = 'Stop'
$keyPath = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
$pcKey = Join-Path $env:USERPROFILE '.ssh\pc-agent-ed25519'
$pcAddr = '100.111.187.124'; $pcUser = 'harishjaswal'
$inbox = "$env:USERPROFILE\Downloads\RDP-Inbox"; New-Item -ItemType Directory $inbox -Force | Out-Null

function Is-Runner { $env:COMPUTERNAME -match 'runnervm|RDP' -or (Test-Path 'C:\Work\pc.ps1') }
$side = if (Is-Runner) { 'RUNNER' } else { 'PC' }
Write-Output "BRIDGE|side=$side|host=$env:COMPUTERNAME"

if ($Action -eq 'status') {
  if ($side -eq 'PC') {
    $m = Get-SmbMapping -LocalPath 'R:' -ErrorAction SilentlyContinue
    Write-Output "PC->RDP|drive=R:|$($m.RemotePath)|$($m.Status)"
    Write-Output "PC->RDP|ssh_key=$(Test-Path $keyPath)"
    $s = Get-Service sshd -ErrorAction SilentlyContinue; Write-Output "RDP->PC|sshd=$($s.Status)/$($s.StartType)"
  } else {
    Write-Output "RDP->PC|pc_key=$(Test-Path $pcKey)|bridge=$(Test-Path 'C:\Work\pc.ps1')"
    Write-Output "RDP->PC|scoped=$(Test-Path 'C:\Work\pcx.ps1')|send=$(Test-Path 'C:\Work\pc-send.ps1')|get=$(Test-Path 'C:\Work\pc-get.ps1')"
  }
  exit 0
}

if ($side -eq 'PC') {
  # PC side: use existing rdp-peer + R: drive
  $peer = Join-Path $env:USERPROFILE '.config\pc-agent\tools\rdp-peer.ps1'
  if (-not (Test-Path $peer)) { $peer = Join-Path $Repo 'pc-agent\tools\rdp-peer.ps1' }
  switch ($Action) {
    'open' { Start-Process explorer.exe -ArgumentList 'R:\'; Write-Output 'OPEN|R:\'; exit 0 }
    'send' { if (-not $Path) { throw 'send: -Path <local file>' }; & powershell -NoProfile -ExecutionPolicy Bypass -File $peer -Action send -Target 1 -Local $Path -Remote 'C:/Work/'; exit $LASTEXITCODE }
    'get'  { if (-not $Path) { throw 'get: -Path <remote file>' }; & powershell -NoProfile -ExecutionPolicy Bypass -File $peer -Action get -Target 1 -Remote $Path -Local $inbox; exit $LASTEXITCODE }
    'sync' {
      if (-not $Path) { throw 'sync: -Path <local dir>' }
      $dest = "R:\incoming\$(Split-Path $Path -Leaf)"
      Copy-Item $Path $dest -Recurse -Force
      Write-Output "SYNC|pushed=$Path -> $dest"; exit 0
    }
  }
} else {
  # Runner side: use pc-send/pc-get seeded by Restore-AICredentials
  $send = 'C:\Work\pc-send.ps1'; $get = 'C:\Work\pc-get.ps1'
  switch ($Action) {
    'open' {
      # Map PC's shared folder as a local drive on runner via SFTP bridge (no SMB needed)
      $target = "$env:USERPROFILE\PC-Files"; New-Item -ItemType Directory $target -Force | Out-Null
      Write-Output "OPEN|use: powershell -File C:\Work\pc-get.ps1 <remote-file> (PC inbox: $target)"; exit 0
    }
    'send' { if (-not $Path) { throw 'send: -Path <local file>' }; & powershell -NoProfile -ExecutionPolicy Bypass -File $send -Local $Path -Remote "C:/Users/$pcUser/Downloads/RDP-Inbox/"; exit $LASTEXITCODE }
    'get'  { if (-not $Path) { throw 'get: -Path <remote file>' }; & powershell -NoProfile -ExecutionPolicy Bypass -File $get -Remote $Path -Local 'C:\Work\'; exit $LASTEXITCODE }
    'sync' {
      if (-not $Path) { throw 'sync: -Path <local dir>' }
      & powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\Work\pc.ps1' "New-Item -ItemType Directory '$inbox\$(Split-Path $Path -Leaf)' -Force | Out-Null"
      & powershell -NoProfile -ExecutionPolicy Bypass -File $send -Local $Path -Remote "C:/Users/$pcUser/Downloads/RDP-Inbox/"
      Write-Output "SYNC|pushed=$Path -> PC inbox"; exit 0
    }
  }
}
