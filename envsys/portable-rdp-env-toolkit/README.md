# Persistent 6-Hour RDP Environment Toolkit

Purpose: rebuild a disposable Windows GitHub Actions runner so your project workspace, supported application configuration/state, and Docker bind-mounted data can return on the next runner.

## What persists

The default map persists:
- OpenCode global config: `%USERPROFILE%\.config\opencode`
- OpenCode application/session data: `%USERPROFILE%\.local\share\opencode`
- Claude Code user data/config: `%USERPROFILE%\.claude`
- Git config
- PowerShell profiles

OpenCode documents its Windows application data under `%USERPROFILE%\.local\share\opencode`, including `auth.json`, logs and project/session data. Claude Code documents user memory under `~/.claude/CLAUDE.md` and project instructions such as `CLAUDE.md` / `.claude` files. See official references below.

## One-time setup

1. Put this toolkit in `C:\Work` on the runner.
2. Finish your normal one-time setup: OpenCode, Claude Code, Docker Compose, agents, project files, etc.
3. Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\Capture-First-Setup.ps1
```

4. Run your existing `Snapshot-VPSWork.ps1` so `C:\Work\PersistentEnvironment` reaches the VPS.

## Every new runner

Run `Restore-Bootstrap.ps1` from the runner bootstrap. It restores profile/application state, executes your existing `Install-MyStack.ps1`, restores again (because installers can recreate directories), then starts `Start-MyAutomation.ps1`.

## Continuous protection

Before each existing VPS snapshot, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Work\Sync-PersistentEnvironment.ps1 -Mode Capture
```

This makes the supported user environment part of `C:\Work`, which your existing snapshot system already handles.

## Docker

Use host bind mounts under `C:\Work\docker\data\...` for persistent data. Recreate containers with `docker compose up -d` on every runner. Do not assume Docker containers or unnamed/named volumes survive runner deletion.

## Authentication

The toolkit deliberately does NOT copy credential stores by default. OpenCode documents that its application data includes `auth.json`, which contains authentication data. Persisting that file in ordinary snapshots would place OAuth/API credentials into the snapshot repository. Prefer GitHub Actions secrets or another dedicated secret store for credentials. GitHub documents repository/environment secrets for injecting sensitive values into workflow runtime.

If you intentionally choose to persist credential material, add an explicit encrypted-secrets design; do not simply enable raw credential copying.

## Safety properties

- Restore is merge/copy; it does not delete unexpected live files.
- The existing snapshot system remains the authoritative versioning/integrity layer.
- Missing optional profile directories are SKIP, not failure.
- Script errors return non-zero.
- Docker persistence is checked but never modifies containers automatically.

## Official references

OpenCode config: https://opencode.ai/v2/docs/config
OpenCode storage/auth: https://dev.opencode.ai/docs/troubleshooting/
Claude Code setup: https://docs.anthropic.com/en/docs/claude-code/getting-started
Claude Code memory: https://docs.anthropic.com/en/docs/claude-code/memory
GitHub Actions secrets: https://docs.github.com/en/actions/concepts/security/secrets
