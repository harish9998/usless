#Requires -Version 5.1
# Restore-AICredentials.ps1 - login-free boot for AI CLIs.
# Decodes base64 zips from repo secrets (passed as env by the workflow) and
# writes them where each tool expects them. Never prints secret contents.
# Secrets consumed (set via gh secret set):
#   OPENCODE_CONFIG_B64  zip{opencode.json}
#   OPENCODE_AUTH_B64    zip{auth.json}
#   QODER_AUTH_B64       zip{qoder_user, qoder_machine_id}
#   GH_TOKEN_RESTORE     raw GitHub PAT for gh CLI on the server
$ErrorActionPreference = 'Continue'

function Restore-Zip {
  param([string]$B64, [string]$DestDir)
  if ([string]::IsNullOrWhiteSpace($B64)) { Write-Host 'RESTORE|SKIP empty-blob'; return $false }
  try {
    $bytes = [Convert]::FromBase64String($B64)
    $zip = Join-Path $env:TEMP '_restore-blob.zip'
    [IO.File]::WriteAllBytes($zip, $bytes)
    if (Test-Path $DestDir) { Remove-Item $DestDir -Recurse -Force -ErrorAction SilentlyContinue }
    Expand-Archive -Path $zip -DestinationPath $DestDir -Force
    return $true
  } catch { Write-Host "RESTORE|FAILED|$($_.Exception.Message)"; return $false }
}

# --- opencode: config (providers/keys) + auth store ---
$ocDir   = Join-Path $env:USERPROFILE '.config\opencode'
$ocShare = Join-Path $env:USERPROFILE '.local\share\opencode'
if (Restore-Zip $env:OPENCODE_CONFIG_B64 (Join-Path $env:TEMP '_occfg')) {
  New-Item -ItemType Directory $ocDir -Force | Out-Null
  Copy-Item (Join-Path $env:TEMP '_occfg\opencode.json') $ocDir -Force
  Write-Host 'RESTORE|OPENCODE|CONFIG=OK'
}
if (Restore-Zip $env:OPENCODE_AUTH_B64 (Join-Path $env:TEMP '_ocauth')) {
  New-Item -ItemType Directory $ocShare -Force | Out-Null
  Copy-Item (Join-Path $env:TEMP '_ocauth\auth.json') $ocShare -Force
  Write-Host 'RESTORE|OPENCODE|AUTH=OK'
}

# --- qoder (INTL CLI): .auth\user + machine_id ---
if (Restore-Zip $env:QODER_AUTH_B64 (Join-Path $env:TEMP '_qauth')) {
  $qd = Join-Path $env:USERPROFILE '.qoder\.auth'
  New-Item -ItemType Directory $qd -Force | Out-Null
  Copy-Item (Join-Path $env:TEMP '_qauth\qoder_user') (Join-Path $qd 'user') -Force
  Copy-Item (Join-Path $env:TEMP '_qauth\qoder_machine_id') (Join-Path $qd 'machine_id') -Force
  Write-Host 'RESTORE|QODER|AUTH=OK'
}

# --- git identity (not a secret, but part of baseline) ---
git config --global user.name 'harish9998'
git config --global user.email 'Harishvideoexpert@gmail.com'
Write-Host 'RESTORE|GIT|IDENTITY=OK'

# --- gh CLI token on the server (persists for future shells via setx) ---
if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN_RESTORE)) {
  $envDir = 'C:\Work\env'
  New-Item -ItemType Directory $envDir -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $envDir 'GH_TOKEN.txt'), $env:GH_TOKEN_RESTORE)
  setx GH_TOKEN $env:GH_TOKEN_RESTORE | Out-Null
  Write-Host 'RESTORE|GH_TOKEN|OK (setx; active in new shells)'
}

Write-Host 'RESTORE|BASELINE=DONE'
