#Requires -Version 5.1
# tests/Run-LocalTests.ps1 - offline tests (no runner required). Reports pass/fail honestly.
$ErrorActionPreference = 'Continue'
$repo = (Get-Item $PSScriptRoot).Parent.FullName
$pass = 0; $fail = 0
function T([string]$name, [scriptblock]$check) {
  try { if (& $check) { "PASS|$name"; $script:pass++ } else { "FAIL|$name"; $script:fail++ } }
  catch { "FAIL|$name|$($_.Exception.Message)"; $script:fail++ }
}
# 1. Parse all new PowerShell
foreach ($f in @('scripts\remote-common.ps1','scripts\remote-connect.ps1','scripts\remote-jobs.ps1','scripts\remote-drive.ps1','scripts\remote-monitor.ps1','scripts\scheduler.ps1','pc-agent\worker\worker.ps1','envsys\Deploy-HybridWorker.ps1')) {
  T "parse:$f" { $e=$null;$t=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $f),[ref]$t,[ref]$e); $e.Count -eq 0 }
}
# 2. Python compile
T 'python:compile_mcp' { python -m py_compile (Join-Path $repo 'pc-agent\mcp\hybrid_mcp.py'); $LASTEXITCODE -eq 0 }
# 3. Scheduler conservative decisions
$sched = Join-Path $repo 'scripts\scheduler.ps1'
T 'sched:ffmpeg_remote' { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $sched -JobType ffmpeg -InputSizeGB 0.3; "$o" -match 'DECISION\|REMOTE' }
T 'sched:archive_local' { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $sched -JobType archive; "$o" -match 'DECISION\|LOCAL' }
T 'sched:low_ram_guard' { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $sched -JobType ffmpeg -RemoteRamFreeGB 2; "$o" -match 'DECISION\|LOCAL' }
T 'sched:short_lifetime_guard' { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $sched -JobType ffmpeg -RunnerRemainingMin 10; "$o" -match 'DECISION\|LOCAL' }
T 'sched:large_input_guard' { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $sched -JobType ffmpeg -InputSizeGB 8; "$o" -match 'DECISION\|LOCAL' }
# 4. Worker: local execution + status (mocked job dir, no runner)
$tmp = Join-Path $env:TEMP "hybrid-test-$([guid]::NewGuid().ToString('N').Substring(0,6))"
New-Item -ItemType Directory $tmp -Force | Out-Null
$jid = 'testworker1'; $jd = Join-Path $tmp $jid; New-Item -ItemType Directory $jd -Force | Out-Null
$job = @{id=$jid;type='python';createdAt=(Get-Date).ToUniversalTime().ToString('o');priority=1;status='queued';arguments=@('-c','print(123)');inputManifest=@();outputs=@();timeoutSec=30;retries=0;attempt=1;checksums=@{}}
[IO.File]::WriteAllText((Join-Path $jd 'job.json'), ($job | ConvertTo-Json -Depth 12))
T 'worker:executes_and_marks_succeeded' {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'pc-agent\worker\worker.ps1') -JobId $jid -Root $tmp | Out-Null
  $r = Get-Content (Join-Path $jd 'job.json') -Raw | ConvertFrom-Json
  ($r.status -eq 'succeeded') -and ((Get-Content (Join-Path $jd 'log.txt') -Raw) -match '123')
}
T 'worker:terminal_idempotent' {
  $before = (Get-Item (Join-Path $jd 'job.json')).LastWriteTime
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'pc-agent\worker\worker.ps1') -JobId $jid -Root $tmp
  "$out" -match 'SKIP'
}
T 'worker:rejects_unregistered_handler' {
  $j2 = 'testdeny'; $d2 = Join-Path $tmp $j2; New-Item -ItemType Directory $d2 -Force | Out-Null
  $job2 = @{id=$j2;type='powershell';status='queued';arguments=@('-c','evil');timeoutSec=30;retries=0}
  [IO.File]::WriteAllText((Join-Path $d2 'job.json'),($job2|ConvertTo-Json -Depth 12))
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'pc-agent\worker\worker.ps1') -JobId $j2 -Root $tmp
  "$out" -match 'unregistered handler'
}
T 'worker:rejects_path_outside_jobdir' {
  $j3 = 'testpath'; $d3 = Join-Path $tmp $j3; New-Item -ItemType Directory $d3 -Force | Out-Null
  $job3 = @{id=$j3;type='ffmpeg';status='queued';arguments=@('C:\Windows\System32\cmd.exe');timeoutSec=30;retries=0}
  [IO.File]::WriteAllText((Join-Path $d3 'job.json'),($job3|ConvertTo-Json -Depth 12))
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'pc-agent\worker\worker.ps1') -JobId $j3 -Root $tmp
  "$out" -match 'path outside job dir rejected'
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
# 5. MCP allowlist via protocol
$mcpReq = '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"remote_delete_all","arguments":{}}}'
T 'mcp:denies_unlisted_tool' {
  $o = $mcpReq | python (Join-Path $repo 'pc-agent\mcp\hybrid_mcp.py')
  "$o" -match 'DENY'
}
T 'mcp:lists_6_tools' {
  $r = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | python (Join-Path $repo 'pc-agent\mcp\hybrid_mcp.py')
  ($r | ConvertFrom-Json).result.tools.Count -eq 6
}
# 6. Virtual drive: local mapping + DPAPI credential round-trip
T 'drive:mapped_or_capable' {
  $d = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\remote-drive.ps1') -Action status
  "$d" -match 'DRIVE\|R:'
}
T 'drive:setups_parse' {
  $e=$null; $t=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'envsys\Setup-RemoteShare.ps1'),[ref]$t,[ref]$e)
  $e.Count -eq 0
}
T 'drive:dpapi_roundtrip' {
  $f = "$env:USERPROFILE\.usless\smb-cred.blob"
  if (-not (Test-Path $f)) { return $false }
  $p = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\Secure-Credential.ps1') -Action read 2>$null
  $p.Length -ge 8
}
"RESULT|pass=$pass|fail=$fail"
if ($fail -gt 0) { exit 1 }