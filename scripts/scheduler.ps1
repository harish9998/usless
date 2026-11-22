#Requires -Version 5.1
# scheduler.ps1 - conservative resource-aware placement decision (Phase 6).
# Returns LOCAL or REMOTE with reasons. Never claims merged hardware.
param(
  [string]$JobType = 'ffmpeg',
  [double]$InputSizeGB = 0.5,
  [double]$LocalCpuPct = 50,
  [double]$LocalRamFreeGB = 8,
  [double]$RemoteCpuPct = 10,
  [double]$RemoteRamFreeGB = 12,
  [bool]$RemoteGpu = $false,
  [int]$RunnerRemainingMin = 300
)
$reasons = @()
$remote = $false
switch ($JobType.ToLower()) {
  'ffmpeg'    { $remote = $true; $reasons += 'video rendering: prefer remote CPU' }
  'python'    { $remote = $true; $reasons += 'python processing: remote OK' }
  'build'     { $remote = ($LocalCpuPct -gt 70); $reasons += 'build: based on local CPU headroom' }
  'docker'    { $remote = $true; $reasons += 'docker: remote engine' }
  'archive'   { $remote = $false; $reasons += 'archive: lightweight, keep local' }
  default     { $remote = $false; $reasons += 'unknown type: conservative local' }
}
# Conservative guards
if ($InputSizeGB -gt 5) { $remote = $false; $reasons += "input ${InputSizeGB}GB > 5GB: transfer overhead high, keep local" }
if ($RemoteRamFreeGB -lt 4) { $remote = $false; $reasons += 'remote RAM <4GB: keep local' }
if ($RunnerRemainingMin -lt 30) { $remote = $false; $reasons += 'runner lifetime <30min: keep local' }
if ($LocalRamFreeGB -lt 2) { $remote = $true; $reasons += 'local RAM <2GB: offload' }
if ($JobType -match 'gpu' -and -not $RemoteGpu) { $remote = $false; $reasons += 'GPU task but remote GPU not verified' }
$decision = if ($remote) { 'REMOTE' } else { 'LOCAL' }
Write-Output "DECISION|$decision|$($reasons -join '; ')"
