# ENVSYS - persistent Windows environment on disposable runners

Source of truth: **Telegram Drive** (250 GB) via its local REST API (`localhost:8550`),
or any `LocalDir` path for dev/test. Runners are disposable ~6h workers.

## Files (`scripts/envsys/`)

| File | Role |
|---|---|
| `Storage-Backend.ps1` | `LocalDir` + `TelegramRest` providers: upload/download/list/delete/size, retries, size-verify |
| `Protect-SnapshotSecrets.ps1` | fail-closed gate: filename + content scan, exit 2 = do not publish |
| `Capture-WindowsEnvironment.ps1` | desired-state capture (workspace manifest, app maps, env/PATH, registry allowlist, power, tasks, services, firewall list, docker map, software inventory) |
| `Restore-WindowsEnvironment.ps1` | deterministic reconcile incl. deletions + digest verify + `{{SECRET:NAME}}` injection |
| `Publish-EnvSnapshot.ps1` | capture > scan > zip > split(1.5GB) > upload > verify > atomic latest > prune |
| `Invoke-EnvBootstrap.ps1` | fresh-runner phases: IDENTIFY FETCH VERIFY RESTORE PROVISION SECRETS SERVICES HEALTH READY |
| `Test-EnvSystem.ps1` | harness: 18 pass / 0 fail / 7 documented skips on reference box |

Related (repo root `scripts/`): `machine.manifest.json`, `Install-MyStack.ps1`,
`Start-MyAutomation.ps1`, `JobQueue.ps1`, `Watch-Relaunch.ps1`, `Relaunch-RDP.ps1`,
`portable-rdp-env-toolkit/` (profile layer).

## One-time setup

1. On a live runner (or any Windows box with your tools): arrange `C:\Work`
   (projects, `Install-MyStack.ps1`, `machine.manifest.json`, `docker\compose.yml`,
   `openclaw\config`, toolkit under `C:\Work\PersistentEnvironmentToolkit`).
2. In Telegram Drive desktop app: sign in, Settings > REST API > enable, copy API key.
3. Repo secret `TG_API_KEY` = that key. Seed `C:\Work\envsys\` + toolkit into
   `C:\Work` once (it syncs afterwards); first `Publish-EnvSnapshot` creates `envsnap/latest.json`.

## Daily use

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Relaunch-RDP.ps1
# connect with printed IP; work in C:\Work; snapshots publish every ~15 min.
```

## Recovery after runner death

Watcher (or manual relaunch) dispatches a replacement: bootstrap fetches `latest.json`,
verifies digest, restores, provisions missing tools, starts automation, health-gates,
prints RDP READY. Corrupt `latest` → operator is told to point at `previous`
(retention always keeps it); restore refuses bad state rather than applying it.

## Limits (honest)

- Telegram: 2 GB/file (we split), no directories (we ship zips), app must run signed-in
  wherever upload/download happens; first auth is interactive.
- Heartbeat ~5 min, snapshots ~15 min: up to 15 min of work at risk; corruption rolls
  back to previous-good, never forward.
- Services needing device-bound login (OS credential store, browser sessions) restore
  config only and report reauthentication - secrets are never dumped to snapshots.
