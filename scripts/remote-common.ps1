#Requires -Version 5.1
# remote-common.ps1 - shared helpers for the hybrid workstation scripts.
# Dot-source only. Never dispatches a runner unless -AllowDispatch is passed explicitly.
$ErrorActionPreference = 'Stop'

function Resolve-Runner {
  param([string]$Target = '1', [switch]$AllowDispatch, [string]$Repo = "$env:USERPROFILE\usless")
  $launcher = Join-Path $Repo 'scripts\Launch-RDP.ps1'
  if (-not (Test-Path $launcher)) { throw "Launch-RDP.ps1 not found: $launcher" }
  # Resolve via -List (machine-readable) then use -Id: PS5.1 -File + -Index
  # splatting is unreliable, but -Id works consistently.
  $listRaw = & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -List 2>$null
  $listLine = @($listRaw | Where-Object { "$_" -like 'LIST|*' } | Select-Object -Last 1)[0]
  if (-not $listLine) { throw "No live runner. Start one with 'rdp' first (or use -AllowDispatch)." }
  if ($Target -match '^\d{7,}$') {
    $chosen = @($listRaw | Where-Object { "$_" -match "run=$Target " } | Select-Object -Last 1)[0]
    if (-not $chosen) { $chosen = $listLine }  # caller supplied an id not yet listed; fall back to newest
  } else {
    $idx = [int]$Target; $lines = @($listRaw | Where-Object { "$_" -like 'LIST|[[]*' })
    $chosen = if ($idx -ge 1 -and $idx -le $lines.Count) { $lines[$idx - 1] } else { $listLine }
  }
  if (-not $chosen -or $chosen -notmatch 'run=(\d+)') { throw "Could not parse runner list" }
  $rid = [regex]::Match($chosen, 'run=(\d+)').Groups[1].Value
  $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -Id $rid -PrintIp 2>$null
  $line = @($raw | Where-Object { "$_" -like 'IP|*' } | Select-Object -Last 1)[0]
  if (-not $line) { throw "No live runner for '$Target'. Start one with 'rdp' first (or use -AllowDispatch)." }
  $p = $line -split '\|'
  return [pscustomobject]@{ Ip = $p[1]; RunId = $p[2]; User = $p[3] }
}
function Get-SshKey {
  $k = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
  if (-not (Test-Path $k)) { throw "SSH key missing: $k" }
  return $k
}
function Clear-StaleKey([string]$Ip) {
  $kh = Join-Path $env:USERPROFILE '.ssh\known_hosts'
  if (-not (Test-Path $kh)) { return }
  $lines = @(Get-Content $kh -ErrorAction SilentlyContinue)
  $kept = @($lines | Where-Object { $_ -notmatch [regex]::Escape($Ip) })
  if ($kept.Count -ne $lines.Count) { [IO.File]::WriteAllLines($kh, $kept) }
}
function New-SshArgs([object]$Runner, [int]$Timeout = 20) {
  Clear-StaleKey $Runner.Ip
  return @('-o','BatchMode=yes','-o',"ConnectTimeout=$Timeout",'-o','StrictHostKeyChecking=accept-new','-i',(Get-SshKey),'-l',$Runner.User,$Runner.Ip)
}
function Test-RunnerSsh([object]$Runner) {
  $out = & ssh @(New-SshArgs $Runner) "Write-Output HYBRID-SSH-OK" 2>$null
  return ($LASTEXITCODE -eq 0 -and ($out -join ' ') -match 'HYBRID-SSH-OK')
}
# Run a PowerShell script block remotely, encoded (quote-safe). Returns stdout lines.
function Invoke-RemoteScript([object]$Runner, [string]$Script) {
  $b64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $out = & ssh @(New-SshArgs $Runner 30) "powershell -NoProfile -EncodedCommand $b64" 2>$null
  $ErrorActionPreference = $prev
  if ($LASTEXITCODE -ne 0) { throw "Remote command failed (exit $LASTEXITCODE)" }
  return $out
}
function Invoke-RemoteFs([object]$Runner, [string]$Verb, [string]$Path, [string]$Dest = '') {
  $script = "powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\RemoteWorkspace\worker\fs.ps1' -Action $Verb -Path '$Path'" + $(if ($Dest) { " -Dest '$Dest'" } else { '' })
  $out = & ssh @(New-SshArgs $Runner 30) $script 2>&1
  if ($LASTEXITCODE -ne 0 -or ("$out" -match '^ERR\|')) { throw "RemoteFS $Verb failed: $($out -join ' ')" }
  return $out
}
function Copy-ToRunner([object]$Runner, [string]$Local, [string]$Remote) {
  # $Remote is the DESTINATION DIRECTORY. Never append the staged source leaf.
  $stage = "_hybrid_$(Split-Path $Local -Leaf)"
  $leaf = Split-Path $Local -Leaf
  $isDir = Test-Path $Local -PathType Container
  Invoke-RemoteFs $Runner 'mkdir' $Remote | Out-Null
  if ($isDir) {
    & scp -r -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i (Get-SshKey) "$Local\." "$($Runner.User)@$($Runner.Ip):$stage"
    if ($LASTEXITCODE -ne 0) { throw "Upload failed: $Local" }
    Invoke-RemoteFs $Runner 'movecontents' $stage $Remote | Out-Null
  } else {
    & scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i (Get-SshKey) $Local "$($Runner.User)@$($Runner.Ip):$stage"
    if ($LASTEXITCODE -ne 0) { throw "Upload failed: $Local" }
    $dest = if ($Remote.EndsWith('\')) { "$Remote$leaf" } else { "$Remote\$leaf" }
    Invoke-RemoteFs $Runner 'move' $stage $dest | Out-Null
  }
  Write-Output "UPLOADED|$Remote"
}
function Copy-FromRunner([object]$Runner, [string]$Remote, [string]$Local) {
  $leaf = Split-Path $Remote -Leaf
  $stage = "_hybrid_$leaf"
  Invoke-RemoteFs $Runner 'copy' $Remote $stage | Out-Null
  $destDir = if (Test-Path $Local -PathType Container) { $Local } else { Split-Path $Local -Parent }
  New-Item -ItemType Directory $destDir -Force | Out-Null
  & scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -i (Get-SshKey) "$($Runner.User)@$($Runner.Ip):$stage" $destDir
  if ($LASTEXITCODE -ne 0) { throw "Download failed: $Remote" }
  # Rename staged file back to the original filename
  $stagedLocal = Join-Path $destDir $stage
  $finalLocal = Join-Path $destDir $leaf
  if (Test-Path $stagedLocal) { if (Test-Path $finalLocal) { Remove-Item $finalLocal -Force }; Rename-Item -LiteralPath $stagedLocal -NewName $leaf -Force }
  Invoke-RemoteFs $Runner 'move' $stage 'C:\Work\_trash' | Out-Null
}
function Get-FileSha256([string]$Path) {
  # Get-FileHash is unavailable in some Windows PowerShell 5.1 hosts; use .NET directly.
  $stream = [IO.File]::OpenRead($Path)
  try { $sha = [Security.Cryptography.SHA256]::Create(); return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-','').ToLowerInvariant() }
  finally { $stream.Dispose() }
}
function Write-JsonAtomic([string]$Path, $Object) {
  $tmp = "$Path.tmp"; $json = $Object | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
  Move-Item $tmp $Path -Force
}
