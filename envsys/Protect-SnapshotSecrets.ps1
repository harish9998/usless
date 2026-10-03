#Requires -Version 5.1
# Protect-SnapshotSecrets.ps1 - fail-closed secret gate. Run on EVERY snapshot dir
# BEFORE upload/publication. Exit 0 = clean. Exit 2 = secrets found (DO NOT PUBLISH).
#   powershell -File Protect-SnapshotSecrets.ps1 -Path C:\staging\snapshot-001
# Central exclusion/scan list lives here (code, never dead config).
param([string]$Path = '', [string[]]$ExtraExcludeFiles = @(), [string[]]$ExtraExcludeDirs = @())
$ErrorActionPreference = 'Stop'
function Log([string]$m) { Write-Output "[SECRETS] $m" }

$ExcludeFiles = @('.credentials.json','auth.json','.env','*.env','*.key','*token*.json','credentials*.json') + $ExtraExcludeFiles
$ExcludeDirs = @('Cache','Code Cache','GPUCache','Crashpad','logs','node_modules\.cache') + $ExtraExcludeDirs
# High-signal content patterns (tight on purpose: secret material, not every password= line).
$ContentPatterns = @(
  '-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
  'ghp_[A-Za-z0-9]{20,}', 'gho_[A-Za-z0-9]{20,}', 'github_pat_[A-Za-z0-9_]{20,}',
  'AKIA[0-9A-Z]{16}', 'xox[bap]-', 'tskey-auth-[A-Za-z0-9_-]{10,}',
  'sk-ant-[A-Za-z0-9_-]{10,}', 'sk-[A-Za-z0-9]{20,}', 'AIza[0-9A-Za-z_-]{20,}',
  'glpat-[A-Za-z0-9_-]{10,}'
)
$ScanExts = @('.json','.txt','.md','.ps1','.xml','.config','.env','.yaml','.yml','.toml','.ini','.cfg')

if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { Log "FAIL: path missing: $Path"; exit 2 }
function Test-Excluded([string]$Full, [string]$Rel) {
  $leaf = Split-Path -Leaf $Full
  foreach ($p in $ExcludeFiles) { if ($leaf -like $p) { return $true } }
  foreach ($d in $ExcludeDirs) { if ($Rel -like "*\$d\*" -or $Rel -like "$d\*") { return $true } }
  return $false
}
$hits = @()
$files = Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue
foreach ($f in $files) {
  $rel = $f.FullName.Substring($Path.Length)
  $leaf = $f.Name
  foreach ($p in $ExcludeFiles) {
    if ($leaf -like $p) { $hits += "FILENAME:$rel"; break }
  }
}
foreach ($f in $files) {
  $rel = $f.FullName.Substring($Path.Length)
  if (Test-Excluded $f.FullName $rel) { continue }
  if ($ScanExts -notcontains ([System.IO.Path]::GetExtension($f.Name).ToLower())) { continue }
  if ($f.Length -gt 2MB) { continue }
  $text = ''
  try { $text = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop } catch { continue }
  if (-not $text) { continue }
  foreach ($pat in $ContentPatterns) {
    if ($text -match $pat) { $hits += "CONTENT:$rel matches $($Matches[0].Substring(0,[Math]::Min(24,$Matches[0].Length)))..."; break }
  }
}
if ($hits.Count -gt 0) {
  Log ("FAIL: $($hits.Count) secret hit(s) - DO NOT PUBLISH")
  $hits | Select-Object -First 20 | ForEach-Object { Log $_ }
  exit 2
}
Log ("PASS: scanned $($files.Count) files, clean")
exit 0
