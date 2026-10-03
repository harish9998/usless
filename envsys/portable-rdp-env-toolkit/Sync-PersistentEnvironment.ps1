[CmdletBinding()]
param(
    [ValidateSet('Capture','Restore','Verify')]
    [string]$Mode = 'Capture',
    [string]$ConfigPath = "$PSScriptRoot\persistent-environment.json",
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Log([string]$Message) { Write-Output "[PersistEnv] $Message" }
function Fail([string]$Message) { Write-Error "[PersistEnv] $Message"; exit 1 }

if (-not (Test-Path -LiteralPath $ConfigPath)) { Fail "Config not found: $ConfigPath" }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$root = [Environment]::ExpandEnvironmentVariables([string]$config.persistentRoot)
$root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($root)
New-Item -ItemType Directory -Force -Path $root | Out-Null

function Expand-Path([string]$Path) {
    $p = [Environment]::ExpandEnvironmentVariables($Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($p)
}

$AlwaysExcludeFiles = @('.credentials.json', 'auth.json', '.env', '*.env', '*.key', '*token*.json', 'credentials*.json')
$AlwaysExcludeDirs = @()

function Test-ExcludedFile([string]$Name) {
    foreach ($pat in $AlwaysExcludeFiles) { if ($Name -like $pat) { return $true } }
    return $false
}

function Copy-Tree([string]$Source,[string]$Target,[bool]$Mirror) {
    if (-not (Test-Path -LiteralPath $Source)) { return 3 }
    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    $args = @($Source,$Target,'/E','/COPY:DAT','/DCOPY:DAT','/R:1','/W:1','/XJ','/NFL','/NDL','/NP')
    if ($Mirror) { $args += '/MIR' }
    # excludedNames from config was previously dead config: enforce it now (/XF files, /XD dirs).
    $xf = @($AlwaysExcludeFiles) + @($config.excludedNames | Where-Object { $_ -notmatch '[\\/]' })
    $xd = @($AlwaysExcludeDirs) + @($config.excludedNames | Where-Object { $_ -match '^[A-Za-z0-9 _-]+$' -and $_ -notmatch '\.' })
    if ($xf) { $args += '/XF'; $args += $xf }
    if ($xd) { $args += '/XD'; $args += $xd }
    & robocopy @args | Out-Null
    return $LASTEXITCODE
}

switch ($Mode) {
    'Capture' {
        Log "CAPTURE started: $root"
        foreach ($item in $config.paths) {
            if (-not $item.enabled) { continue }
            $src = Expand-Path ([string]$item.source)
            $dst = Join-Path $root ([string]$item.target)
            if (-not (Test-Path -LiteralPath $src)) { Log "SKIP missing: $($item.name) -> $src"; continue }
            $isFile = -not (Test-Path -LiteralPath $src -PathType Container)
            if ($isFile) {
                if (Test-ExcludedFile (Split-Path -Leaf $src)) { Log "SKIP secret/cache file: $($item.name)"; continue }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                Copy-Item -LiteralPath $src -Destination $dst -Force
                Log "COPIED file: $($item.name)"
            } else {
                $rc = Copy-Tree $src $dst $true
                if ($rc -gt 7) { Fail "Robocopy failed for $($item.name), code $rc" }
                Log "COPIED tree: $($item.name) (robocopy=$rc)"
            }
        }
        Log "CAPTURE complete"
    }
    'Restore' {
        Log "RESTORE started: $root"
        foreach ($item in $config.paths) {
            if (-not $item.enabled) { continue }
            $src = Join-Path $root ([string]$item.target)
            $dst = Expand-Path ([string]$item.source)
            if (-not (Test-Path -LiteralPath $src)) { Log "SKIP no snapshot data: $($item.name)"; continue }
            $isFile = -not (Test-Path -LiteralPath $src -PathType Container)
            if ($isFile) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
                Copy-Item -LiteralPath $src -Destination $dst -Force
                Log "RESTORED file: $($item.name)"
            } else {
                $rc = Copy-Tree $src $dst $false
                if ($rc -gt 7) { Fail "Robocopy failed for $($item.name), code $rc" }
                Log "RESTORED tree: $($item.name) (robocopy=$rc)"
            }
        }
        Log "RESTORE complete"
    }
    'Verify' {
        $errors = 0
        Log "VERIFY started"
        foreach ($item in $config.paths) {
            if (-not $item.enabled) { continue }
            $dst = Expand-Path ([string]$item.source)
            $src = Join-Path $root ([string]$item.target)
            $srcExists = Test-Path -LiteralPath $src
            $dstExists = Test-Path -LiteralPath $dst
            if ($srcExists -ne $dstExists) {
                Log "DRIFT $($item.name): snapshot=$srcExists live=$dstExists"
                $errors++
            } else { Log "OK $($item.name)" }
        }
        if ($errors -gt 0 -and $Strict) { Fail "VERIFY failed with $errors drift item(s)" }
        Log "VERIFY complete: errors=$errors"
    }
}
