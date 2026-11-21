#Requires -Version 5.1
# Strip-RDP.ps1 - remove preinstalled GitHub-image app FOLDERS not needed for render/dev.
# Direct folder deletion (fast, reliable) instead of slow MSI uninstallers.
# Never touches Git, Node, Python, gh, Tailscale, Chrome, ffmpeg, ImageMagick, npm, C:\Work.
$ErrorActionPreference = 'SilentlyContinue'
function Say([string]$m) { Write-Host "STRIP|$m" }

# Only these exact known-unused app folders. Keep list enforced implicitly (not in this list).
$targets = @(
  'C:\rtools45',                              # R build tools 3.1GB
  'C:\Strawberry',                            # Perl 543MB
  'C:\Program Files\MongoDB',                 # MongoDB 1.7GB
  'C:\Program Files\MySQL',                   # MySQL 577MB
  'C:\Program Files\PostgreSQL',              # PostgreSQL 1GB
  'C:\Program Files\R',                       # R 189MB
  'C:\Program Files\Unity Hub',               # Unity 594MB
  'C:\Program Files (x86)\Epic Games',        # Epic launcher 256MB
  'C:\Program Files\Epic Online Services',
  'C:\Program Files (x86)\Epic Online Services',
  'C:\Program Files\Mozilla Firefox',         # 361MB
  'C:\Program Files\OpenSSL',                 # 837MB
  'C:\Program Files\CMake',                   # 134MB
  'C:\Program Files\mongosh',                 # MongoDB shell 198MB
  'C:\Program Files (x86)\Inno Setup 6',
  'C:\Program Files\Mercurial',
  'C:\Program Files (x86)\AWS CLI',
  'C:\Program Files\AWS CLI',
  'C:\Program Files (x86)\AWS SAM CLI',
  'C:\Program Files\AWS SAM CLI',
  'C:\Program Files\Git\mingw64\share\doc\Git',  # optional docs only
  'C:\hostedtoolcache\windows\Python\3.11.9',    # old Python versions (keep 3.12/3.15)
  'C:\hostedtoolcache\windows\Python\3.13.17',
  'C:\hostedtoolcache\windows\Python\3.14.10'
)
$freed = 0
foreach ($d in $targets) {
  if (-not (Test-Path $d)) { continue }
  # Safety: never delete if a process is running from it
  $busy = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($d, [StringComparison]::OrdinalIgnoreCase) }
  if ($busy) { Say "SKIP-BUSY|$d"; continue }
  $size = (Get-ChildItem $d -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  cmd /c "rd /s /q `"$d`"" 2>$null
  if (-not (Test-Path $d)) { $freed += $size; Say "REMOVED|$d|$([math]::Round($size/1MB,0))MB" }
}
$free = [math]::Round((Get-PSDrive C).Free/1GB,1)
Say "FREED_MB=$([math]::Round($freed/1MB,0)) DISK_FREE_GB=$free"
Say 'DONE'
