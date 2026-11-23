#Requires -Version 5.1
# health.ps1 - model health tracking (mark unhealthy / rate-limited / recover).
param(
  [ValidateSet('mark','list','recover')][string]$Action = 'list',
  [string]$ModelId = '',
  [ValidateSet('unavailable','ratelimited','failing','healthy')][string]$Reason = 'failing',
  [string]$Root = "$env:USERPROFILE\usless\dualroute"
)
$ErrorActionPreference = 'Stop'
$path = "$Root\registry\health.json"
if (-not (Test-Path $path)) { [IO.File]::WriteAllText($path, '{}') }
$h = Get-Content $path -Raw | ConvertFrom-Json
$policy = Get-Content "$Root\config\routing.json" -Raw | ConvertFrom-Json
switch ($Action) {
  'mark' {
    if (-not $ModelId) { throw 'mark needs -ModelId' }
    $ttl = if ($Reason -eq 'ratelimited') { $policy.health.rateLimitedTtlMinutes } else { $policy.health.unavailableTtlMinutes }
    $until = (Get-Date).AddMinutes($ttl).ToUniversalTime().ToString('o')
    $h | Add-Member -NotePropertyName $ModelId -NotePropertyValue ([ordered]@{ reason=$Reason; until=$until; hits=@($h.$ModelId.hits)+1 }) -Force
    [IO.File]::WriteAllText($path, ($h | ConvertTo-Json -Depth 6))
    Write-Output "HEALTH|marked=$ModelId|$Reason|until=$until"
  }
  'recover' {
    if ($ModelId -and $h.PSObject.Properties[$ModelId]) { $h.PSObject.Properties.Remove($ModelId); [IO.File]::WriteAllText($path, ($h | ConvertTo-Json -Depth 6)); Write-Output "HEALTH|recovered=$ModelId" }
    else { Write-Output 'HEALTH|recover: no model specified' }
  }
  'list' { if ($h.PSObject.Properties.Count -eq 0) { Write-Output 'HEALTH|all-healthy' } else { $h.PSObject.Properties | ForEach-Object { "HEALTH|$($_.Name)|$($_.Value.reason)|until=$($_.Value.until)|hits=$($_.Value.hits.Count)" } } }
}
