# Migration: VPS-sync toolkit -> ENVSYS (Telegram)

What stays: `main.yml` flow, `Install-MyStack.ps1`, `Start-MyAutomation.ps1`,
`machine.manifest.json`, `JobQueue.ps1`, watchers, relaunch scripts,
`portable-rdp-env-toolkit/` (profile layer, now secret-safe by default).

What changes:
1. Storage moves from VPS `scp` to `Storage-Backend` (`TelegramRest`, `LocalDir` fallback).
   Keep VPS steps until Telegram snapshots verify end-to-end, then retire them.
2. Workspace sync (`Sync-VPSWork.ps1`) stays as the manual tool; automation uses
   `Publish-EnvSnapshot.ps1` + `Restore-WindowsEnvironment.ps1`.
3. Secrets: move any lingering values into GitHub Secrets + `{{SECRET:NAME}}`
   template files; never into snapshots.
4. `TG_API_KEY` repo secret + Telegram Drive signed-in wherever publish/restore runs.
5. First publish seeds `envsnap/latest.json`; retention keeps previous-good always.

Order: seed `C:\Work` (envsys + toolkit + stack + compose + configs) > publish once >
verify download+restore on a fresh runner > enable watchdog publish > retire VPS mirror.
