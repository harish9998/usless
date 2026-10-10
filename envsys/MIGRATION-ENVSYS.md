# Migration: VPS-sync toolkit -> ENVSYS (durable store TBD)

What stays: `main.yml` flow, `Install-MyStack.ps1`, `Start-MyAutomation.ps1`,
`machine.manifest.json`, `portable-rdp-env-toolkit/` (profile layer, now secret-safe
by default), `scripts/Relaunch-RDP.ps1` (manual dispatch helper).

What changed:
1. The VPS `scp` workspace sync was REMOVED from the active workflow — no permanent
   VPS exists, so it could never be the source of truth. Missing/removed storage now
   reports `PERSISTENCE NOT READY` instead of a misleading green restore.
2. Storage moves to `Storage-Backend` (`TelegramRest` provisional, `LocalDir` for
   dev/test). `Sync-VPSWork.ps1` never existed in this repo's history; automation uses
   `Publish-EnvSnapshot.ps1` + `Restore-WindowsEnvironment.ps1`.
3. Secrets: values live only in GitHub Secrets + `{{SECRET:NAME}}` template files;
   never in snapshots. Never paste secrets into chat, logs, or repo files.
4. `TG_API_KEY` repo secret + Telegram Drive signed-in wherever publish/restore runs.
   FRESH-RUNNER GATE: unattended install + sign-in + `/health` + publish/verify is
   still unproven. If it fails, pick a different adapter before building further.
5. First publish seeds `envsnap/latest.json`; retention keeps previous-good always.
6. No watcher/relaunch daemons ever existed in this repo (`JobQueue.ps1`,
   `Watch-*.ps1` were aspirational doc references, since removed). Relaunch is an
   explicit manual dispatch; do not add perpetual scheduled RDP relaunches to keep a
   general-purpose desktop alive — keep runs within the repo's testing/publishing use.

Order: seed `C:\Work` (envsys + toolkit + stack + compose + configs) > prove the
`Test-EnvSystem.ps1` LocalDir chain on a real runner > prove the Telegram gate (or
swap backends) > only then consider retiring the NOT-READY status.
