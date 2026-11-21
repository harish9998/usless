#Requires -Version 5.1
# Strip-RDP.ps1 - remove preinstalled GitHub-image apps NOT needed for video render/dev.
# Frees DISK (these apps don't use CPU/RAM unless running). Idempotent + safe:
# never touches Git, Node, Python, gh, Tailscale, Chrome, ffmpeg, ImageMagick, npm, C:\Work.
$ErrorActionPreference = 'SilentlyContinue'
function Say([string]$m) { Write-Host "STRIP|$m" }

# DisplayName patterns to uninstall (regex). Everything else is left alone.
$junk = @(
  '^Rtools', '^R for Windows', '^MongoDB', '^PostgreSQL', '^MySQL',
  '^Unity Hub', '^Epic Games Launcher', '^Epic Online Services',
  '^Strawberry Perl', '^AWS Command Line', '^AWS SAM', '^Mercurial ',
  '^TortoiseSVN', '^sbt ', '^WiX Toolset', '^CMake', '^Inno Setup',
  '^Mozilla Firefox', '^OpenSSL ', '^mongosh'
)
$keep = @('Git','GitHub CLI','Node.js','Python','Tailscale','Google Chrome','ImageMagick','ffmpeg','Microsoft Visual','PowerShell','Windows','OpenSSH','VCRedist','.NET','C++','7-Zip','curl','jq','gh')
$junk = $junk | Where-Object { $_ -ne '^Git ' }

$paths = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
$all = Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
$removed = 0
foreach ($app in $all) {
  $n = $app.DisplayName
  $isKeep = $keep | Where-Object { $n -like "*$_*" }
  if ($isKeep) { continue }
  $match = $junk | Where-Object { $n -match $_ }
  if (-not $match) { continue }
  # Skip anything with no uninstall string (can't remove cleanly)
  if (-not $app.UninstallString) { continue }
  Say "REMOVING|$n"
  try {
    if ($app.UninstallString -match 'MsiExec') {
      $guid = [regex]::Match($app.UninstallString, '\{[0-9A-Fa-f-]+\}').Value
      if ($guid) { Start-Process msiexec.exe -ArgumentList "/X $guid /quiet /norestart" -Wait -ErrorAction SilentlyContinue }
    } elseif ($app.UninstallString -match 'unins000|uninstall-postgresql|helper\.exe') {
      $exe = ([regex]::Match($app.UninstallString, '"([^"]+)"')).Groups[1].Value
      if (-not $exe) { $exe = $app.UninstallString }
      if (Test-Path $exe) { Start-Process -FilePath $exe -ArgumentList '/VERYSILENT /NORESTART' -Wait -ErrorAction SilentlyContinue }
    }
    $removed++
  } catch { Say "FAIL|$n|$($_.Exception.Message)" }
}
Say "REMOVED=$removed"
# Delete leftover top-level folders of removed apps (best-effort, safe paths only)
foreach ($d in @('C:\rtools45','C:\Strawberry','C:\Program Files\MongoDB','C:\Program Files\MySQL','C:\Program Files\PostgreSQL','C:\Program Files\R','C:\Program Files\Unity Hub','C:\Program Files (x86)\Epic Games','C:\Program Files\Mercurial','C:\Program Files\CMake','C:\Program Files\OpenSSL','C:\Program Files\mongosh','C:\Program Files\Mozilla Firefox','C:\Program Files (x86)\Inno Setup 6')) {
  if (Test-Path $d) { cmd /c "rd /s /q `"$d`"" 2>$null; if (-not (Test-Path $d)) { Say "FOLDER-GONE|$d" } }
}
$free = [math]::Round((Get-PSDrive C).Free/1GB,1)
Say "DISK_FREE_GB=$free"
Say 'DONE'
