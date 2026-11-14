# ============================================================
# RDP command suite - installed by workflow step
# "Configure RDP commands" into the RDP user's PowerShell profile.
# Commands:
#   rdp            -> open the RDP session GUI (mstsc) using the card
#   rdp new        -> dispatch a fresh successor RDP run (bypass 6h cap)
#   rdp delete     -> cancel this runner's workflow (kills session)
#   rdp delete -Old <n> -> also cancel up to n other queued/in-progress runs
# Reads: C:\Work\rdp-connection.txt (card), C:\Work\.gh-token, C:\Work\.gh-repo
# ============================================================
$script:RdpCardPath = 'C:\Work\rdp-connection.txt'
$script:RdpTokenPath = 'C:\Work\.gh-token'
$script:RdpRepoPath = 'C:\Work\.gh-repo'

function rdp {
    param(
        [Parameter(Position = 0)][string]$Action = 'open',
        [int]$Old = 0
    )
    if (-not (Test-Path $script:RdpCardPath)) {
        Write-Host 'RDP|ERR|CARD_MISSING (C:\Work\rdp-connection.txt not found)'
        return
    }
    $props = @{}
    Get-Content $script:RdpCardPath | ForEach-Object {
        $p = $_ -split '=', 2
        if ($p.Count -eq 2) { $props[$p[0].Trim()] = $p[1].Trim() }
    }
    $addr = $props['address']
    $user = $props['username']
    $pass = $props['password']
    $runId = $props['run_id']
    $repo = 'harish9998/usless'
    if (Test-Path $script:RdpRepoPath) { $repo = (Get-Content $script:RdpRepoPath -Raw).Trim() }
    $headers = $null
    if (Test-Path $script:RdpTokenPath) {
        $tok = (Get-Content $script:RdpTokenPath -Raw).Trim()
        if ($tok) {
            $headers = @{ Authorization = "Bearer $tok"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
        }
    }

    switch ($Action.ToLower()) {
        'open' {
            if (-not $addr) { Write-Host 'RDP|ERR|NO_ADDRESS_IN_CARD'; return }
            if ($pass) { cmdkey /generic:TERMSRV/$addr /user:$user /pass:$pass | Out-Null }
            Write-Host "RDP|OPEN|$addr user=$user"
            Start-Process mstsc -ArgumentList "/v:$($addr):3389"
        }
        'new' {
            if (-not $headers) { Write-Host 'RDP|ERR|NO_TOKEN (C:\Work\.gh-token missing)'; return }
            $body = @{ ref = 'main'; inputs = @{ mode = 'rdp' } } | ConvertTo-Json
            try {
                Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$repo/actions/workflows/main.yml/dispatches" -Headers $headers -Body $body | Out-Null
                Write-Host 'RDP|NEW|SUCCESSOR_DISPATCHED'
            } catch { Write-Host "RDP|NEW|FAILED|err=$($_.Exception.Message)" }
        }
        'delete' {
            if (-not $headers) { Write-Host 'RDP|ERR|NO_TOKEN'; return }
            if (-not $runId) { Write-Host 'RDP|ERR|NO_RUN_ID_IN_CARD'; return }
            try {
                Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$repo/actions/runs/$runId/cancel" -Headers $headers | Out-Null
                Write-Host "RDP|DELETE|RUN_CANCELLED|$runId"
            } catch { Write-Host "RDP|DELETE|FAILED|err=$($_.Exception.Message)" }
            if ($Old -gt 0) {
                try {
                    $runs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs?per_page=50" -Headers $headers
                    $targets = @($runs.workflow_runs | Where-Object { $_.id -ne $runId -and $_.status -in 'in_progress', 'queued' } | Select-Object -First $Old)
                    foreach ($r in $targets) {
                        try {
                            Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$repo/actions/runs/$($r.id)/cancel" -Headers $headers | Out-Null
                            Write-Host "RDP|DELETE|CANCELLED_OLD|$($r.id)"
                        } catch { Write-Host "RDP|DELETE|SKIP|$($r.id)|err=$($_.Exception.Message)" }
                    }
                } catch { Write-Host "RDP|DELETE|LIST_FAILED|err=$($_.Exception.Message)" }
            }
        }
        default { Write-Host 'usage: rdp [open|new|delete [-Old <n>]]' }
    }
}
