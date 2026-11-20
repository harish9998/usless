#Requires -Version 5.1
# Optimize-RDP.ps1 - lean-on-boot tuning for dev/render runners.
# Reclaims CPU/RAM/IO wasted on background OS features. Idempotent.
$ErrorActionPreference = 'SilentlyContinue'
function Say([string]$m) { Write-Host "OPT|$m" }

# 1. High-performance power plan + never sleep / never lock (long renders must not stall)
powercfg /S 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
powercfg /CHANGE standby-timeout-ac 0
powercfg /CHANGE hibernate-timeout-ac 0
powercfg /CHANGE monitor-timeout-ac 0
Say 'POWER=high-performance,no-sleep,no-lock'

# 2. Stop CPU-hungry background services that don't help a render box
foreach ($svc in @('WSearch','SysMain','DiagTrack','dmwappushservice','TrkWks')) {
  $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
  if ($s -and $s.Status -eq 'Running') { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue }
  if ($s) { Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue }
}
Say 'SERVICES=search/superfetch/telemetry-disabled'

# 3. Defender exclusions for work dirs + render tools (huge IO win; ephemeral box)
$excludePaths = @('C:\Work','C:\npm','C:\Program Files\nodejs','C:\Users\RDP\Documents')
foreach ($p in $excludePaths) { if (Test-Path $p) { Add-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue } }
foreach ($proc in @('ffmpeg.exe','ffprobe.exe','node.exe','python.exe','blender.exe')) { Add-MpPreference -ExclusionProcess $proc -ErrorAction SilentlyContinue }
Say 'DEFENDER=exclusions-added'

# 4. Disable animations/visual effects (less GPU/CPU for desktop)
$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'
Set-ItemProperty -Path $adv -Name VisualFXSetting -Value 2 -ErrorAction SilentlyContinue
Say 'VISUALEFFECTS=best-performance'

# 5. Skip Windows Update on an ephemeral 6h box (no updates mid-render)
if (-not (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU')) {
  New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
}
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -Value 1 -Type DWord -ErrorAction SilentlyContinue
Say 'WINUPDATE=disabled(ephemeral)'

# 6. Minimal auto-starts: keep sshd/Tailscale/termService only
$autoruns = @('C:\Users\RDP\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup','C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup')
foreach ($d in $autoruns) {
  Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'tailscale' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
Say 'STARTUP=trimmed'

Say 'DONE'
