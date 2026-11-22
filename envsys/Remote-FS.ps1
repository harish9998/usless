#Requires -Version 5.1
# Remote-FS.ps1 - filesystem verbs on runner, invoked via SSH -File (quote-safe).
param(
  [Parameter(Mandatory=$true)][ValidateSet('move','hash','mkdir','exists','list','copy','movecontents')][string]$Action,
  [string]$Path = '', [string]$Dest = ''
)
$ErrorActionPreference = 'Stop'
function Full([string]$p) { if ([IO.Path]::IsPathRooted($p)) { return $p }; return [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE $p)) }
try {
  switch ($Action) {
    'mkdir'  { $f=Full $Path; New-Item -ItemType Directory $f -Force | Out-Null; "OK|mkdir=$f" }
    'exists' { $f=Full $Path; "OK|exists=$([bool](Test-Path $f))" }
    'move'   { $src=Full $Path; $dst=Full $Dest; $d = Split-Path $dst -Parent; if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }; if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }; if (Test-Path -LiteralPath $src -PathType Container) { [IO.Directory]::Move($src,$dst) } else { [IO.File]::Move($src,$dst) }; "OK|moved=$dst" }
    'copy'   { $src=Full $Path; $dst=Full $Dest; $d = Split-Path $dst -Parent; if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }; if (Test-Path -LiteralPath $src -PathType Container) { Copy-Item -LiteralPath $src $dst -Recurse -Force } else { [IO.File]::Copy($src,$dst,$true) }; "OK|copied=$dst" }
    'movecontents' { $src=Full $Path; $dst=Full $Dest; New-Item -ItemType Directory $dst -Force | Out-Null; Get-ChildItem -LiteralPath $src -Force | ForEach-Object { $t = Join-Path $dst $_.Name; if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force }; [IO.Directory]::Move($_.FullName, $t) }; Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction SilentlyContinue; "OK|contents=$dst" }
    'hash'   { $f=Full $Path; $s = [IO.File]::OpenRead($f)
      try { $h = [Security.Cryptography.SHA256]::Create(); "OK|sha256=$(([BitConverter]::ToString($h.ComputeHash($s)) -replace '-','').ToLowerInvariant())" }
      finally { $s.Dispose() }
    }
    'list'   { $f=Full $Path; Get-ChildItem -LiteralPath $f -Force | ForEach-Object { "ITEM|$($_.Name)|$($_.Length)|$($_.PSIsContainer)" } }
  }
} catch { "ERR|$($_.Exception.Message)"; exit 2 }
