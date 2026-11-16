# PC-Agent v2: RDP AI Agent access to this PC (permission-gated)

This PC (`harishjaswal@100.111.187.124`, Tailscale, RTX 3050) can be used by the RDP runner's AI agent.

## Keys (on runner, auto-restored every boot)
- **Full key** `pc-agent-ed25519` → `C:\Work\pc.ps1` (unrestricted SSH). Use for: tunnels, admin ops you explicitly approve.
- **Scoped key** `pc-agent-scoped-ed25519` → `C:\Work\pcx.ps1` (forced through gateway). **Default for agent.**

## Runner helpers
| Command | Purpose |
|---|---|
| `powershell C:\Work\pcx.ps1 "help"` | gateway verbs (v2) |
| `powershell C:\Work\pcx.ps1 "ping"` | connectivity + GPU info |
| `powershell C:\Work\pcx.ps1 "ls/read/write <path>"` | file ops (allowlisted paths) |
| `powershell C:\Work\pcx.ps1 "apps"` / `app-info blender` | allowed apps + resolved paths |
| `powershell C:\Work\pcx.ps1 "run <app> [args]"` | run allowed app, wait for output |
| `powershell C:\Work\pcx.ps1 "launch <app> [args]"` | start GUI app non-blocking |
| `powershell C:\Work\pcx.ps1 "render blender <file.blend> [-f 1 \| -a] [-E CYCLES]"` | headless Blender render on GPU |
| `powershell C:\Work\pcx.ps1 "tunnels"` | allowed tunnel ports |
| `powershell C:\Work\pc.ps1 "<cmd>"` | **full** shell command on PC |
| `powershell C:\Work\pc-tunnel.ps1 -Port 20128` | forward PC localhost port to runner (9router/3081/3082/11434) |
| `powershell C:\Work\pc-send.ps1 .\file.mp4 [remote]` | scp to PC `Downloads\RDP-Inbox` |
| `powershell C:\Work\pc-get.ps1 C:/.../file .` | scp from PC |

## Apps with special access (scoped, permission-gated)
| App | Path | Modes |
|---|---|---|
| **Blender 5.3** | `C:\Program Files\Blender Foundation\Blender 5.3\blender.exe` | `launch` (GUI), `run`/`render` (headless, RTX 3050 GPU) |
| **Roblox Studio** | `...\Roblox\Versions\version-63eb6055af4e4688\RobloxStudioBeta.exe` | `launch` (GUI), plugin/MCP present (`%LOCALAPPDATA%\Roblox\mcp.bat`) |
| ffmpeg/ffprobe, python, node, git, code, etc. | resolved via PATH/policy | `run` / `launch` as applicable |

Rendering example (headless, uses GPU): `pcx.ps1 "render blender C:\Users\HARISHJASWAL\Documents\scene.blend -E CYCLES -o //RDP-Inbox/frame_ -a"` (blend must be in a read-allowed path; write outputs to a write-allowed path).

## Permissions — YOU control (edit on this PC)
- **Policy:** `C:\Users\HARISHJASWAL\.config\pc-agent\policy.json` (v2)
  - `paths.read/write/deny` — allowed dirs (`.ssh`, opencode secrets, AppData\Roaming denied)
  - `apps.allowed` + `apps.paths` + `apps.gui` — which executables, how to resolve, GUI vs headless
  - `tunnels.allowed_ports` — 20128 9router, 3081 siliconflow-proxy, 3082 freellmapi, 11434 ollama
  - `rendering` — Blender/GPU config
- **Gateway:** `C:\Users\HARISHJASWAL\.config\pc-agent\gateway.ps1` (forced-command for scoped key)
- **SSH auth:** `C:\ProgramData\ssh\administrators_authorized_keys` — scoped key = `command=...gateway.ps1,no-port-forwarding`; full key unrestricted.

## Revoke
- Remove scoped key line from `administrators_authorized_keys` → no scoped ops. Remove full key → no access.
- Delete repo secrets `PC_SSH_KEY_B64` / `PC_SSH_SCOPED_KEY_B64`. Firewall: port 22 only from Tailscale `100.64.0.0/10`.

## Notes
- PC must be on + Tailscale + sshd running. Roblox Studio version path may change on updates — update `apps.paths.robloxstudio` in policy if needed.
- Full key can tunnel PC-local services to runner (`pc-tunnel.ps1`) for MCP/model bridges.
- "PSProfile loaded" noise in SSH output is harmless (PC PowerShell profile).