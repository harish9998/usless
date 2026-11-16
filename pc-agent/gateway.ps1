# gateway.ps1 v2 - permission-gated command dispatcher for runner->PC SSH
# Scoped key is forced here: runner request in $env:SSH_ORIGINAL_COMMAND
# Policy (edit to grant/revoke): C:\Users\HARISHJASWAL\.config\pc-agent\policy.json
param([string]$Cmd = $env:SSH_ORIGINAL_COMMAND)
$ErrorActionPreference = 'Stop'
$policyPath = "$env:USERPROFILE\.config\pc-agent\policy.json"
function Deny([string]$why) { Write-Output "DENY: $why"; exit 2 }
function Ok([string]$msg) { Write-Output $msg }
if (-not (Test-Path $policyPath)) { Deny "no policy file" }
$policy = Get-Content $policyPath -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Cmd)) { $Cmd = 'help' }
$parts = $Cmd.Trim() -split '\s+', 2
$verb = $parts[0].ToLower()
$arg = if ($parts.Count -gt 1) { $parts[1] } else { '' }

function PathAllowed([string]$p, [string]$mode) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }
  $full = [IO.Path]::GetFullPath($p)
  foreach ($d in $policy.paths.deny) { if ($full.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { return $false } }
  $list = if ($mode -eq 'write') { $policy.paths.write } else { $policy.paths.read }
  foreach ($d in $list) { if ($full.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
  return $false
}
function Resolve-App([string]$name) {
  $n = $name.ToLower()
  $allowed = @($policy.apps.allowed | ForEach-Object { $_.ToLower() })
  if ($allowed -notcontains $n) { return $null }
  $p = $policy.apps.paths.PSObject.Properties[$n]
  if ($p) { return $p.Value } else { return $name }
}
function In-List($list, [string]$name) { @($list | ForEach-Object { $_.ToLower() }) -contains $name.ToLower() }

switch ($verb) {
  'help' {
    @"
PC-AGENT gateway v2 (scoped). Verbs:
  help | ping | policy
  ls <path> | read <path> | write <path>  (stdin -> file, write-allowlisted)
  apps | app-info <name>
  run <app> [args...]       run allowed app (headless/cmd), waits for output
  launch <app> [args...]    start GUI app non-blocking (blender, robloxstudio, code, explorer)
  render blender <.blend> [extra args]   headless Blender render on GPU (shortcut)
  tunnels                   allowed tunnel ports/services
Paths/apps/ports are controlled in policy.json on this PC.
"@
  }
  'ping' { Ok "PC-AGENT-OK v2 user=$env:USERNAME host=$env:COMPUTERNAME gpu=RTX3050" }
  'policy' { Get-Content $policyPath -Raw }
  'ls' {
    if (-not (PathAllowed $arg 'read')) { Deny "path not in read allowlist: $arg" }
    Get-ChildItem -LiteralPath $arg -ErrorAction Stop | Select-Object Mode,Length,LastWriteTime,Name | Format-Table -AutoSize | Out-String -Width 4096
  }
  'read' {
    if (-not (PathAllowed $arg 'read')) { Deny "path not in read allowlist: $arg" }
    Get-Content -LiteralPath $arg -Raw -ErrorAction Stop
  }
  'write' {
    $p = $arg.Trim()
    if (-not (PathAllowed $p 'write')) { Deny "path not in write allowlist: $p" }
    $dir = Split-Path $p -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
    $stdin = [Console]::In.ReadToEnd()
    [IO.File]::WriteAllText($p, $stdin)
    Ok "WROTE $p ($($stdin.Length) chars)"
  }
  'apps' { ($policy.apps.allowed -join "`n") + "`n--- paths ---`n" + ($policy.apps.paths | ConvertTo-Json -Compress) }
  'app-info' {
    $exe = Resolve-App $arg
    if (-not $exe) { Deny "app not allowed: $arg" }
    $gui = In-List $policy.apps.gui $arg
    "app=$arg exe=$exe gui=$gui exists=$(Test-Path $exe)"
  }
  'run' {
    $rp = $arg.Trim() -split '\s+', 2
    $name = $rp[0]; $rargs = if ($rp.Count -gt 1) { $rp[1] } else { '' }
    $exe = Resolve-App $name
    if (-not $exe) { Deny "app not allowed: $name (see: apps)" }
    # Run and stream output. For long jobs caller's SSH session stays open.
    if ($rargs) {
      $psi = New-Object System.Diagnostics.ProcessStartInfo
      $psi.FileName = $exe; $psi.Arguments = $rargs
      $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
      $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $p = [System.Diagnostics.Process]::Start($psi)
      $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
      $p.WaitForExit()
      if ($out) { Write-Output $out }
      if ($err) { Write-Output $err }
      exit $p.ExitCode
    } else { & $exe; exit $LASTEXITCODE }
  }
  'launch' {
    $rp = $arg.Trim() -split '\s+', 2
    $name = $rp[0]; $largs = if ($rp.Count -gt 1) { $rp[1] } else { '' }
    $exe = Resolve-App $name
    if (-not $exe) { Deny "app not allowed: $name" }
    if (-not (In-List $policy.apps.gui $name)) { Deny "app '$name' not marked GUI-launchable (use: run)" }
    if ($largs) { Start-Process -FilePath $exe -ArgumentList $largs | Out-Null }
    else { Start-Process -FilePath $exe | Out-Null }
    Ok "LAUNCHED $name ($exe)"
  }
  'render' {
    # render blender <blend-file> [extra blender args, e.g. -f 1 or -a or -E CYCLES]
    $rp = $arg.Trim() -split '\s+', 3
    $engine = $rp[0].ToLower()
    if ($engine -ne 'blender') { Deny "render supports: blender" }
    $blend = if ($rp.Count -gt 2) { $rp[1] } else { $rp[1] }
    $extra = if ($rp.Count -gt 3) { $rp[2] } else { '' }
    if (-not $blend) { Deny "usage: render blender <file.blend> [extra args]" }
    if (-not (PathAllowed $blend 'read')) { Deny "blend file not in read allowlist: $blend" }
    $exe = Resolve-App 'blender'
    $bargs = "-b `"$blend`" $extra".Trim()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe; $psi.Arguments = $bargs
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd(); $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($out) { Write-Output $out }
    if ($err) { Write-Output $err }
    Ok "RENDER-DONE blender exit=$($p.ExitCode)"
    exit $p.ExitCode
  }
  'tunnels' { $policy.tunnels.labels | ConvertTo-Json -Compress }
  default { Deny "unknown verb '$verb'. Try: help" }
}
