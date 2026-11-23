#Requires -Version 5.1
# tests/Run-DualRouteTests.ps1 - offline routing/fallback tests (no LLM calls).
$ErrorActionPreference = 'Continue'
$root = "$env:USERPROFILE\usless\dualroute"
$pass=0;$fail=0
function T($name,$sb){ try{ if(& $sb){ "PASS|$name";$script:pass++ }else{ "FAIL|$name";$script:fail++ } }catch{ "FAIL|$name|$($_.Exception.Message)";$script:fail++ } }
function Disc { & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\discover.ps1" -Quiet 2>&1 | Out-Null }
function Route($t){ & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\route.ps1" -Task $t 2>&1 | Select-Object -Last 1 }
function Health($a,$m){ & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\health.ps1" -Action $a -ModelId $m 2>&1 | Out-Null }
$hp = "$root\registry\health.json"

T 'parse_all' { $ok=$true; foreach($f in @('discover','route','health','track','refresh')){ $e=$null;$t=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$root\scripts\$f.ps1",[ref]$t,[ref]$e); if($e.Count){$ok=$false} }; $ok }
# clean slate
[IO.File]::WriteAllText($hp,'{}'); Disc
T 'economy_default' { $r=Route 'fix typo in README'; "$r" -match 'model=opencode/hy4-flash-free' -and "$r" -match 'role=default_economy' }
T 'difficult_uses_deepseek' { $r=Route 'debug complex concurrency race in multi-file refactor'; "$r" -match 'deepseek-v4.1-flash-free' }
T 'escalation_from_economy' { $r=& powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\route.ps1" -Task 'fix typo' -Escalated 2>&1|Select-Object -Last 1; "$r" -match 'preferred_free_specialist' }
T 'paid_disabled' { $c=Get-Content "$root\registry\catalog.json" -Raw|ConvertFrom-Json; -not $c.roles.optional_paid_specialist }
# fallback
Health 'mark' 'opencode/deepseek-v4.1-flash-free'; Disc
T 'unavailable_triggers_fallback' { $c=Get-Content "$root\registry\catalog.json" -Raw|ConvertFrom-Json; $c.roles.preferred_free_specialist -ne 'opencode/deepseek-v4.1-flash-free' -and $c.roles.preferred_free_specialist -ne $null }
T 'fallback_is_free' { $c=Get-Content "$root\registry\catalog.json" -Raw|ConvertFrom-Json; $m=@($c.models|Where-Object id -eq $c.roles.preferred_free_specialist)[0]; [bool]$m.free }
Health 'recover' 'opencode/deepseek-v4.1-flash-free'; Disc
T 'recovery_restores_preferred' { $c=Get-Content "$root\registry\catalog.json" -Raw|ConvertFrom-Json; $c.roles.preferred_free_specialist -eq 'opencode/deepseek-v4.1-flash-free' }
T 'refresh_preserves_on_failure' { $before=Get-Content "$root\registry\catalog.json" -Raw; $bak="$root\registry\catalog.previous.json"; Copy-Item "$root\registry\catalog.json" $bak -Force; [IO.File]::WriteAllText("$root\scripts\discover.ps1.bak",'broken'); & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\refresh.ps1" 2>&1 | Out-Null; Remove-Item "$root\scripts\discover.ps1.bak" -Force; (Get-Content "$root\registry\catalog.json" -Raw).Length -gt 100 }
T 'tracking_records' { & powershell -NoProfile -ExecutionPolicy Bypass -File "$root\scripts\track.ps1" -Action record -ModelId 'test' -Role 'default_economy' -Complexity 'moderate' -InputTokens 5 -OutputTokens 3 2>&1 | Out-Null; $lines=Get-Content "$root\tracking\usage.jsonl" -EA SilentlyContinue; $lines.Count -gt 0 }
"RESULT|pass=$pass|fail=$fail"
if($fail -gt 0){ exit 1 }
