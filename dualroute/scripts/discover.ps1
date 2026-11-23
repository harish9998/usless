#Requires -Version 5.1
# discover.ps1 - DualRoute model discovery. Queries LIVE opencode catalog + config metadata.
# Writes registry\catalog.json and resolves logical roles from config\routing.json.
# Never prints or stores API keys.
param(
  [string]$Root = "$env:USERPROFILE\usless\dualroute",
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }
$cfgPath = "$env:USERPROFILE\.config\opencode\opencode.json"

# 1. LIVE catalog from opencode CLI
$prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
$liveRaw = & opencode models 2>$null
$ErrorActionPreference = $prev
$live = @($liveRaw | Where-Object { $_ -match '^[\w@.-]+/[\w@./-]+$' } | ForEach-Object { $_.Trim() })

# 2. Config metadata (pricing, context, capabilities) for configured providers
$meta = @{}
if (Test-Path $cfgPath) {
  $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
  foreach ($p in $cfg.provider.PSObject.Properties) {
    foreach ($m in $p.Value.models.PSObject.Properties) {
      $id = "$($p.Name)/$($m.Name)"
      $v = $m.Value
      $in = 0.0; $out = 0.0
      if ($v.cost -and $v.cost.input) { $in = [double]$v.cost.input }
      if ($v.cost -and $v.cost.output) { $out = [double]$v.cost.output }
      $meta[$id] = [ordered]@{
        id=$id; source='config'; provider=$p.Name
        free=($in -eq 0 -and $out -eq 0)
        inputPrice=$in; outputPrice=$out
        tool=[bool]$v.tool_call; vision=[bool]$v.vision; reasoning=[bool]$v.reasoning
        context=[int]$v.limit.context; maxOutput=[int]$v.limit.output
        healthy=$true; lastSeen=(Get-Date).ToUniversalTime().ToString('o')
      }
    }
  }
}

# 3. Merge: every LIVE model not in config gets inferred metadata from its id
foreach ($id in $live) {
  if (-not $meta.ContainsKey($id)) {
    $provider = ($id -split '/')[0]
    $isFree = ($id -match 'free|zen|ollama|opencode/' -or $provider -in @('opencode','zen-free','ollama'))
    $meta[$id] = [ordered]@{
      id=$id; source='live-cli'; provider=$provider
      free=[bool]$isFree; inputPrice=$(if($isFree){0.0}else{0.0}); outputPrice=0.0
      tool=$true; vision=($id -match 'vl|vision|vision|gemma'); reasoning=($id -match 'think|reason|r1|nemotron.*ultra')
      context=$(if($id -match '1m|1m-ctx'){1000000}else{128000}); maxOutput=32768
      healthy=$true; lastSeen=(Get-Date).ToUniversalTime().ToString('o')
      note='inferred-from-live-id (verify before paid use)'
    }
  }
}

# 4. Preserve health state from health.json AND existing registry
$healthPath = "$Root\registry\health.json"
if (Test-Path $healthPath) {
  $h = Get-Content $healthPath -Raw | ConvertFrom-Json
  foreach ($hp in $h.PSObject.Properties) {
    if ($meta.ContainsKey($hp.Name) -and $hp.Value.until) {
      $until = [datetimeoffset]::Parse($hp.Value.until)
      if ($until -gt [DateTimeOffset]::UtcNow) { $meta[$hp.Name].healthy = $false; $meta[$hp.Name].unhealthyReason = $hp.Value.reason }
      else { $meta[$hp.Name].healthy = $true }
    }
  }
}
$regPath = "$Root\registry\catalog.json"
# (health is sourced ONLY from health.json above; no stale registry carry-over)

# 5. Resolve logical roles
$routing = Get-Content "$Root\config\routing.json" -Raw | ConvertFrom-Json
$resolved = @{}
foreach ($role in $routing.roles.PSObject.Properties) {
  $name = $role.Name; $def = $role.Value
  $req = $def.requirements
  $candidates = @($meta.Values | Where-Object {
    $_.healthy -ne $false -and
    (-not $req.free -or $_.free -eq [bool]$req.free) -and
    (-not $req.mustBePaid -or $_.free -eq $false) -and
    (-not $req.tool -or $_.tool) -and
    (-not $req.minContext -or $_.context -ge [int]$req.minContext)
  })
  # Role disabled in policy -> no resolution
  if ($def.enabled -eq $false) { $resolved[$name] = $null; continue }
  $preferred = @($def.preferredIds | Where-Object { $candidates.id -contains $_ })
  if ($preferred.Count -gt 0) { $chosen = $preferred[0] }
  else {
    $sorted = switch ("$($def.selection)") {
      'highest-ctx-then-reasoning' { $candidates | Sort-Object -Property @{Expression='context';Descending=$true},@{Expression='reasoning';Descending=$true} }
      'reasoning-first-then-ctx' { $candidates | Sort-Object -Property @{Expression='reasoning';Descending=$true},@{Expression='context';Descending=$true} }
      default { $candidates | Sort-Object -Property @{Expression='inputPrice';Descending=$false},@{Expression='context';Descending=$true} }
    }
    $chosen = @($sorted)[0].id
  }
  $resolved[$name] = $chosen
}

$catalog = [ordered]@{
  generatedAt=(Get-Date).ToUniversalTime().ToString('o')
  source='dualroute-discover'
  counts=[ordered]@{ live=$live.Count; total=$meta.Count; free=@($meta.Values|Where-Object free).Count }
  roles=$resolved
  models=@($meta.Values | Sort-Object id)
}
[IO.File]::WriteAllText($regPath, ($catalog | ConvertTo-Json -Depth 12))
Say "DISCOVER|live=$($live.Count)|models=$($meta.Count)|free=$($catalog.counts.free)"
foreach ($r in $resolved.GetEnumerator()) { Say "ROLE|$($r.Key)=$($r.Value)" }
