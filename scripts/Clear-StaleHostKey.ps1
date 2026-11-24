#Requires -Version 5.1
# Clear-StaleHostKey.ps1 - remove stale known_hosts entries for a Tailscale IP.
# Called before SSH connects to a recycled runner IP (host keys change per runner).
param([Parameter(Mandatory=$true)][string]$Ip)
$kh = Join-Path $env:USERPROFILE '.ssh\known_hosts'
if (-not (Test-Path $kh)) { exit 0 }
$lines = @(Get-Content $kh -ErrorAction SilentlyContinue)
$kept = @($lines | Where-Object { $_ -notmatch [regex]::Escape($Ip) })
if ($kept.Count -ne $lines.Count) {
  [IO.File]::WriteAllLines($kh, $kept)
  Write-Output "HOSTKEY|cleared=$Ip"
} else { Write-Output "HOSTKEY|clean=$Ip" }
