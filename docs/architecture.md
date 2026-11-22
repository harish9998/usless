# Hybrid Remote Workstation — implemented architecture

## Layers
- **Local control plane (ASUS laptop):** `rdp*` commands in `scripts/`, local job registry `~/.usless/jobs`, optional MCP bridge.
- **Connectivity:** Tailscale (private) + Windows OpenSSH key auth. `Launch-RDP.ps1 -PrintIp` discovers the active runner's IP from its connection-card artifact.
- **Remote compute plane:** ephemeral runner with `C:\RemoteWorkspace\{projects,incoming,processing,artifacts,cache,datasets,checkpoints,jobs}` and a restricted worker.

## Data flow
`rdp new` → runner boots → `Deploy-HybridWorker.ps1` seeds workspace + worker → local `remote-*.ps1` discovers IP → SSH/SCP → worker executes registered handlers → artifacts pulled to `~/Downloads/RDP-Inbox/<jobid>` → durable manifests on PC survive runner loss.

## Security model
- Tailscale only for SSH/SMB; SSH key `id_ed25519`, never passwords in scripts.
- SMB: SMBv1 refused; port 445 restricted to tailnet; credential from Windows Credential Manager; if SMB unavailable, checksum-verified SCP fallback.
- Worker: allowlisted handlers only (`ffmpeg,python,archive,build,docker`), path-traversal rejection, argument-array execution, timeouts, retries, idempotency (no re-run of terminal/running jobs).
- MCP bridge: 6 allowlisted read-only tools; no credentials, no arbitrary shell, no destructive ops.

## Storage strategy
Git for source; checksum-verified SCP for inputs/artifacts; SMB drive when feasible; TelegramRest/LocalDir storage backend for snapshots (no TeraBox backend present). Runner is disposable — nothing important lives only there.

## Recovery
Local job registry is durable. `remote-jobs.ps1 -Action recover` re-submits non-terminal jobs (attempt <= 3) to a successor runner. Only jobs with explicit checkpoints can resume; others restart idempotently.

## Known limits
No merged hardware (dashboard shows separate local/remote columns). SMB feasibility is probed at runtime, not assumed. Quick Cloudflare tunnel URLs are ephemeral. No GPU on runners assumed.
