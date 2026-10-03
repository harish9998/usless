[CmdletBinding()]
param([string]$ComposePath = 'C:\Work\docker\docker-compose.yml')
$ErrorActionPreference='Stop'

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { Write-Error 'Docker CLI not found.'; exit 1 }
if (-not (Test-Path -LiteralPath $ComposePath)) { Write-Output "[DockerPersist] SKIP compose not found: $ComposePath"; exit 0 }

Write-Output "[DockerPersist] Checking compose file: $ComposePath"
$text = Get-Content -LiteralPath $ComposePath -Raw
if ($text -match '(?m)^\s+volumes:\s*$') {
    Write-Output '[DockerPersist] volumes section found.'
} else {
    Write-Warning '[DockerPersist] No top-level volumes section found. This is not necessarily wrong; verify services use host bind mounts for state.'
}

# Heuristic warning only; this script does not alter containers.
if ($text -match '(?m)^\s+-\s+[A-Za-z0-9_.-]+\s*$' -and $text -match '(?m)^\s+volumes:\s*$') {
    Write-Warning '[DockerPersist] Possible named-volume usage detected. Named volumes must be explicitly exported/restored or replaced with persistent bind mounts.'
}

Write-Output '[DockerPersist] CHECK COMPLETE.'
