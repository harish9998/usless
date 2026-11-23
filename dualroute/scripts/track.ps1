#Requires -Version 5.1
# track.ps1 - record routing decisions + usage quantities. Appends JSONL, prints summary.
param(
  [ValidateSet('record','summary')][string]$Action = 'summary',
  [string]$ModelId = '', [string]$Role = '', [string]$Complexity = '',
  [int]$InputTokens = 0, [int]$OutputTokens = 0, [int]$CacheTokens = 0,
  [switch]$Escalated, [string]$Root = "$env:USERPROFILE\usless\dualroute"
)
$ErrorActionPreference = 'Stop'
$dir = "$Root\tracking"; New-Item -ItemType Directory $dir -Force | Out-Null
$log = "$dir\usage.jsonl"
if ($Action -eq 'record') {
  $entry = [ordered]@{
    ts=(Get-Date).ToUniversalTime().ToString('o'); model=$ModelId; role=$Role; complexity=$Complexity
    input=$InputTokens; output=$OutputTokens; cache=$CacheTokens; escalated=[bool]$Escalated
  }
  Add-Content -Path $log -Value ($entry | ConvertTo-Json -Compress)
  Write-Output "TRACK|recorded|$ModelId|in=$InputTokens|out=$OutputTokens"
  exit 0
}
if (-not (Test-Path $log)) { Write-Output 'TRACK|no-data'; exit 0 }
$rows = @(Get-Content $log | ForEach-Object { try { $_ | ConvertFrom-Json } catch {} })
$inT = ($rows | Measure-Object input -Sum).Sum; $outT = ($rows | Measure-Object output -Sum).Sum
$esc = @($rows | Where-Object escalated).Count
$byModel = $rows | Group-Object model | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Output "TRACK|events=$($rows.Count)|in=$inT|out=$outT|escalations=$esc|rate=$([math]::Round(100*$esc/[Math]::Max(1,$rows.Count),1))%"
Write-Output ("TRACK|models=" + ($byModel -join ','))
