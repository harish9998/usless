#Requires -Version 5.1
# Deploy-HybridWorker.ps1 - placed in C:\Work by workflow; copies worker to remote workspace.
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot '..\pc-agent\worker\worker.ps1'
$dstDir = 'C:\RemoteWorkspace\worker'
New-Item -ItemType Directory $dstDir -Force | Out-Null
foreach ($d in @('projects','incoming','processing','artifacts','cache','datasets','checkpoints','jobs')) { New-Item -ItemType Directory (Join-Path 'C:\RemoteWorkspace' $d) -Force | Out-Null }
if (Test-Path $src) { Copy-Item $src "$dstDir\worker.ps1" -Force; Write-Host "WORKER|deployed=$(Test-Path "$dstDir\worker.ps1")" }
else { Write-Host 'WORKER|source missing - skipped' }
