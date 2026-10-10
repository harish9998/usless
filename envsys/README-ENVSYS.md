# ENVSYS - persistent Windows environment on disposable runners

Source of truth: **Telegram Drive** (provisional — fresh-runner sign-in unproven;
see Limits) via its local REST API (`localhost:8550`), or any `LocalDir` path for
dev/test. Runners are disposable ~6h workers. With no durable store configured the
workflow reports `PERSISTENCE NOT READY` and workspace changes die with the runner.

## Files (`envsys/`; entry script `scripts/Relaunch-RDP.ps1`)

| File | Role |
|---|---|
| `Storage-Backend.ps1` | `LocalDir` + `TelegramRest` providers: upload/download/list/delete/size, retries, size-verify |
| `Protect-SnapshotSecrets.ps1` | fail-closed gate: filename + content scan, exit 2 = do not publish |
| `Capture-WindowsEnvironment.ps1` | desired-state capture (workspace manifest, app maps, env/PATH, registry allowlist, power, tasks, services, firewall list, docker map, software inventory) |
| `Restore-WindowsEnvironment.ps1` | deterministic reconcile incl. deletions + digest verify + `{{SECRET:NAME}}` injection |
| `Publish-EnvSnapshot.ps1` | capture > scan > zip > split(1.5GB) > upload > verify > atomic latest > prune |
| `Invoke-EnvBootstrap.ps1` | fresh-runner phases: IDENTIFY FETCH VERIFY RESTORE PROVISION SECRETS SERVICES HEALTH READY |
| `Test-EnvSystem.ps1` | harness: portable checks everywhere, full publish→restore→corrupt→fallback chain on Windows; per-run counts in `TEST|SUMMARY` (no fixed totals claimed) |

Related: `machine.manifest.json`, `Install-MyStack.ps1`,
`Start-MyAutomation.ps1` (all in `envsys/`, seeded to `C:\Work\envsys`),
`portable-rdp-env-toolkit/` (profile layer), `scripts/Relaunch-RDP.ps1`
(manual dispatch helper — the only relaunch mechanism; no watcher exists because a
watcher cannot survive the runner it runs on).

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

Replacement runners are launched explicitly (manual `workflow_dispatch` via
`scripts\Relaunch-RDP.ps1` or the Actions tab; `test` mode runs only the harness).
Bootstrap fetches `latest.json`, verifies digest, restores, provisions missing tools,
starts automation, health-gates, prints RDP READY. A corrupt `latest` is rejected
automatically and the newest previous-good snapshot is tried (up to 4 candidates,
newest-first); restore refuses bad state rather than applying it. Retention keeps
the latest plus a bounded window (Publish `-Keep`, default 8) and always spares the
previous-good snapshot, so at least one recoverable snapshot survives pruning.

## Limits (honest)

- Telegram is PROVISIONAL, not viable-yet: its REST API belongs to the Telegram Drive
  desktop app (`127.0.0.1:8550`, disabled by default, app must be open and signed in;
  session data is local, API hash lives in the OS credential manager). A fresh runner
  has none of that. Until a clean-runner test proves install → sign-in (or session
  restore) → `/health` → authenticated publish/list/download/hash-verify works
  unattended, do not build on it. If sign-in needs a human every run, change the
  storage backend instead.
- 250 GB capacity, per-file caps (we split zips at 1.5 GB against the 2 GB/file cap),
  and rate limits are unverified against the live service — measure before relying.
- Heartbeat ~5 min, snapshots ~15 min: up to 15 min of work at risk; corruption rolls
  back to previous-good, never forward.
- Services needing device-bound login (OS credential store, browser sessions) restore
  config only and report reauthentication - secrets are never dumped to snapshots.
