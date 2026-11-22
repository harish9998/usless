# Hybrid workstation — install & usage

## Local setup (run once, from your ASUS laptop)
```powershell
# Tailscale already installed; confirm:
tailscale status --self

# Verify SSH key auth to a live runner (start one with `rdp` first):
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\usless\scripts\remote-connect.ps1" -Action check

# Optional: VS Code Remote-SSH extension, then:
#   rdp workspace  (via profile function, or remote-connect.ps1 -Action workspace)
```

## Runner setup (automatic on boot)
`.github/workflows/main.yml` step “Deploy hybrid worker” runs `envsys/Deploy-HybridWorker.ps1`, creating `C:\RemoteWorkspace\...` and `worker.ps1`. Gate: `RDP_HYBRID` variable (absent = on; set `off` to disable).

## OpenCode MCP bridge (optional, read-only tools)
```json
{
  "mcp": {
    "hybrid": {
      "type": "local",
      "command": ["python", "C:\\Users\\HARISHJASWAL\\usless\\pc-agent\\mcp\\hybrid_mcp.py"],
      "enabled": true
    }
  }
}
```
Tools: `remote_status`, `remote_resources`, `remote_worker_list`, `remote_list_jobs`, `remote_drive_status`, `remote_schedule`. No write/destructive tools are exposed.

## Usage
```powershell
rdp                                  # start/connect (existing)
rdp list                             # all live runners
rdp connect                          # SSH terminal to newest runner
rdp workspace                        # open remote project in local VS Code
rdp drive status|check|mount|unmount # SMB feasibility / mapping (SFTP fallback)
rdp monitor                          # local + remote resources, separate columns

# Submit an FFmpeg render (durable manifest on PC):
powershell -File scripts\remote-jobs.ps1 -Action new -JobType ffmpeg -Args @('-i','in.mp4','out.mp4') -Inputs @('C:\vids\in.mp4')
powershell -File scripts\remote-jobs.ps1 -Action submit -JobId <id>
powershell -File scripts\remote-jobs.ps1 -Action status -JobId <id>
powershell -File scripts\remote-jobs.ps1 -Action logs -JobId <id>
powershell -File scripts\remote-jobs.ps1 -Action pull -JobId <id>
powershell -File scripts\remote-jobs.ps1 -Action recover           # after runner replacement
```
Checksum-verified file sync: `scripts\remote-drive.ps1 -Action sync -Direction push|pull -Local <path> -Remote <path>`.

## Tests
`powershell -ExecutionPolicy Bypass -File tests\Run-LocalTests.ps1` — 20 offline tests (parse, compile, scheduler guards, worker execution/idempotency/deny, MCP allowlist). Integration tests requiring a live runner are listed in docs/architecture.md limits.
