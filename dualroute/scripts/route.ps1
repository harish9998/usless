#Requires -Version 5.1
# route.ps1 - DualRoute request classifier + model selector.
# Usage: route.ps1 -Task "<description>" [-Complexity auto|easy|moderate|difficult|complex|critical] [-Escalated]
# Prints ROUTE|... machine-readable line with chosen role+model and reason.
param(
  [Parameter(Mandatory=$true)][string]$Task,
  [string]$Complexity = 'auto',
  [switch]$Escalated,
  [string]$Root = "$env:USERPROFILE\usless\dualroute"
)
$ErrorActionPreference = 'Stop'
$reg = Get-Content "$Root\registry\catalog.json" -Raw | ConvertFrom-Json
$policy = Get-Content "$Root\config\routing.json" -Raw | ConvertFrom-Json

# Classify from task signals (NOT length). Keyword patterns, uppercase-insensitive.
$t = $Task.ToLower()
$difficultSignals = @('debug','refactor','architecture','security','concurrency','race','deadlock','database schema','complex','algorithm','multi-file','integration','memory leak','performance','optimize',' exploit','vulnerab','distributed','consensus')
$criticalSignals = @('production outage','data loss','security breach','payment','auth bypass','destructive','credentials','migration rollback')
$complexity = $Complexity
if ($complexity -eq 'auto') {
  if ($criticalSignals | Where-Object { $t -match [regex]::Escape($_) }) { $complexity = 'critical' }
  elseif ($difficultSignals | Where-Object { $t -match [regex]::Escape($_) }) { $complexity = 'difficult' }
  else { $complexity = 'moderate' }
}
$role = $policy.routing.$complexity
if (-not $role) { $role = 'default_economy' }
if ($Escalated) {
  if ($role -eq 'default_economy') { $role = 'preferred_free_specialist' }
  elseif ($role -eq 'preferred_free_specialist') { $role = 'best_free_coding' }
}
$model = $reg.roles.$role
# FREE-ONLY enforcement: never return a paid model unless explicitly enabled
if ($model) {
  $m = @($reg.models | Where-Object { $_.id -eq $model } | Select-Object -First 1)[0]
  if ($m -and -not $m.free -and -not $policy.policy.allowPaid) {
    $fallbackRole = 'best_free_coding'
    $model = $reg.roles.$fallbackRole
    Write-Output "ROUTE|paid-blocked|fallback=$fallbackRole"
  }
}
Write-Output "ROUTE|complexity=$complexity|role=$role|model=$model|escalated=$Escalated"
