#Requires -Version 5.1
# remote-connect.ps1 - Phase 1 connectivity + Phase 3 dev workspace.
# Usage: remote-connect.ps1 -Action check|connect|workspace|disconnect [-Target <index|runid>] [-AllowDispatch]
param(
  [ValidateSet('check','connect','workspace','disconnect')][string]$Action = 'check',
  [string]$Target = '1', [switch]$AllowDispatch,
  [string]$RemoteDir = 'C:\RemoteWorkspace',
  [string]$Repo = "$env:USERPROFILE\usless"
)
. (Join-Path $PSScriptRoot 'remote-common.ps1')

if ($Action -eq 'disconnect') {
  # Close only VS Code remote windows for runner hosts; never touch local projects.
  $code = Get-Process 'Code' -ErrorAction SilentlyContinue
  if ($code) { Write-Output "DISCONNECT|note=close VS Code remote windows manually ($($code.Count) Code processes running); local projects untouched" }
  else { Write-Output 'DISCONNECT|no VS Code processes' }
  exit 0
}
$runner = Resolve-Runner -Target $Target -AllowDispatch:$AllowDispatch -Repo $Repo
Write-Output "RUNNER|ip=$($runner.Ip)|run=$($runner.RunId)|user=$($runner.User)"
if (-not (Test-RunnerSsh $runner)) { throw "SSH not ready on $($runner.Ip). Runner may still be booting." }
Write-Output 'SSH|OK'
if ($Action -eq 'check') { exit 0 }

# Ensure remote workspace directory convention exists
Invoke-RemoteScript $runner "New-Item -ItemType Directory '$RemoteDir' -Force | Out-Null; foreach (`$d in @('projects','incoming','processing','artifacts','cache','datasets','checkpoints','jobs')) { New-Item -ItemType Directory (Join-Path '$RemoteDir' `$d) -Force | Out-Null }; 'WORKSPACE-READY'" | Out-Null
Write-Output "WORKSPACE|ready=$RemoteDir"
if ($Action -eq 'connect') {
  Write-Output "CONNECT|ssh -l $($runner.User) $($runner.Ip) (interactive terminal)"
  & ssh @(New-SshArgs $runner) -t
  exit $LASTEXITCODE
}
# workspace: open remote folder in local VS Code via Remote-SSH
$code = (Get-Command code -ErrorAction SilentlyContinue).Source
if (-not $code) { throw 'VS Code CLI (code) not found on local PATH' }
$dest = "$($runner.User)@$($runner.Ip):$RemoteDir\projects"
Write-Output "WORKSPACE|opening VS Code Remote-SSH: $dest"
& $code --remote "ssh-remote+$($runner.User)@$($runner.Ip)" $dest
if ($LASTEXITCODE -ne 0) { throw 'VS Code Remote SSH launch failed - is the Remote-SSH extension installed?' }
Write-Output 'WORKSPACE|launched'
