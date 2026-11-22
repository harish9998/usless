#Requires -Version 5.1
# remote-monitor.ps1 - Phase 5/6 unified local+remote dashboard (clearly separate, never merged).
param([string]$Target = '1', [switch]$AllowDispatch, [string]$Repo = "$env:USERPROFILE\usless")
. (Join-Path $PSScriptRoot 'remote-common.ps1')
function Local-Metrics {
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
  $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA|AMD|Radeon' -or ($_.Name -match 'Intel' -and $_.Name -notmatch 'UHD Graphics') } | Select-Object -First 1
  [pscustomobject]@{
    CpuPct=[int]$cpu.Average; RamFree=[math]::Round($os.FreePhysicalMemory/1MB,1); RamTotal=[math]::Round($os.TotalVisibleMemorySize/1MB,1)
    DiskFree=[math]::Round((Get-PSDrive C).Free/1GB,1); Gpu=$(if($gpu){$gpu.Name}else{'none'}); Tail=$(Test-Path "$env:ProgramFiles\Tailscale\tailscale.exe")
  }
}
$local = Local-Metrics
$remote = $null; $runner = $null
try {
  $runner = Resolve-Runner -Target $Target -AllowDispatch:$AllowDispatch -Repo $Repo
  if (Test-RunnerSsh $runner) {
    $s = Invoke-RemoteScript $runner @'
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average
$gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Microsoft|Remote|Microsoft Basic' } | Select-Object -First 1
"CPU=$([int]$cpu.Average)|RAMFREE=$([math]::Round($os.FreePhysicalMemory/1MB,1))|RAMTOTAL=$([math]::Round($os.TotalVisibleMemorySize/1MB,1))|DISK=$([math]::Round((Get-PSDrive C).Free/1GB,1))|GPU=$(if($gpu){$gpu.Name}else{'none'})|DOCKER=$([bool](Get-Command docker -EA SilentlyContinue))|FFMPEG=$([bool](Get-Command ffmpeg -EA SilentlyContinue))|UP=$((Get-Date)-$os.LastBootUpTime)"
'@ | Out-String
    $p = ($s -split '\|')
    $remote = [pscustomobject]@{ CpuPct=$p[0].Replace('CPU=',''); RamFree=$p[1].Replace('RAMFREE=',''); RamTotal=$p[2].Replace('RAMTOTAL=',''); DiskFree=$p[3].Replace('DISK=',''); Gpu=$p[4].Replace('GPU=',''); Docker=$p[5].Replace('DOCKER=',''); Ffmpeg=$p[6].Replace('FFMPEG=',''); Up=$p[7].Replace('UP=','') }
  }
} catch { $remote = $null }
"===================================================="
"             HYBRID COMPUTE MONITOR"
"===================================================="
"LOCAL ASUS                    REMOTE RDP"
"CPU  $($local.CpuPct)%                       CPU  $(if($remote){$remote.CpuPct+'%'}else{'OFFLINE'})"
"RAM  $($local.RamFree)/$($local.RamTotal) GB      RAM  $(if($remote){$remote.RamFree+'/'+$remote.RamTotal+' GB'}else{'OFFLINE'})"
"DISK $($local.DiskFree) GB free       DISK $(if($remote){$remote.DiskFree+' GB free'}else{'OFFLINE'})"
"GPU  $($local.Gpu)      GPU  $(if($remote){$remote.Gpu}else{'OFFLINE'})"
"TAILSCALE $($local.Tail)             $(if($runner){'RUNNER '+$runner.RunId}else{'NO RUNNER'})"
"===================================================="
if ($remote) { "DOCKER=$($remote.Docker) FFMPEG=$($remote.Ffmpeg) UPTIME=$($remote.Up)" }
$jobs = @(Get-ChildItem "$env:USERPROFILE\.usless\jobs" -Filter '*.json' -File -ErrorAction SilentlyContinue)
$active = @($jobs | Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).status -in @('queued','accepted','running','retry_wait') })
"ACTIVE LOCAL JOB RECORDS: $($active.Count)"
