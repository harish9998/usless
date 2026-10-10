# Telegram session setup: one-time export, then runners (SECRET-ADJACENT)

Read this fully before touching anything. The session bundle is a **live
credential for a Telegram account** — treat it like a password. No step here
asks you to paste secrets to any person, chat, log, or repo file. Secrets are
set ONLY in the repo's Settings > Secrets and variables > Actions, by you.

## 0. Rules (non-negotiable)

1. **Dedicated Telegram account.** Use an account created ONLY for environment
   backups — never your personal account. Anyone with write access to this
   (public) repository could exfiltrate workflow-accessible secrets through a
   merged workflow change, so the blast radius must be one throwaway account.
2. **Never** send session files, API keys, or tokens to the coding agent, chat,
   logs, snapshots, archives, or commits. The agent works with file NAMES and
   sizes, never contents.
3. **Rotate/revoke** the backup account's sessions the moment anything looks
   exposed (Telegram Settings > Devices > terminate sessions; revoke the REST
   key by regenerating it in the app).

## 1. One-time interactive setup (your own machine, ~10 min)

1. Install Telegram Drive v3.5.0 (the pinned, source-verified tree) and sign in
   with the DEDICATED backup account (phone number + login code, in the app UI).
2. Settings > REST API > enable, set port 8550, generate the API key. Copy the
   key into a password manager — this becomes `TG_API_KEY`.
3. Confirm the app lists your drive files (proves the session is valid).
4. **Close the app completely** (tray > quit), so the SQLite session checkpoints
   and no WAL/SHM holds unwritten pages. Copying live database files risks a
   torn/inconsistent bundle.
5. From `%APPDATA%\com.cameronamer.telegramdrive\` copy EXACTLY these files to a
   scratch dir (names, never contents, leave the machine):
   `telegram.session`, `telegram.session-wal`, `telegram.session-shm` (last two
   may be absent after a clean quit — that is fine and healthiest),
   `config.json` (tauri-store holding `api_id`; copied VERBATIM, never edited —
   no separate api-id secret is needed because the code reads it from this file).
6. Zip that scratch dir (no password needed; it never travels outside secrets).

## 2. Size gate (measure, do not assume)

GitHub Actions secrets hold **48 KB each**; base64 inflates raw bytes by ~4/3.

```powershell
$raw = (Get-Item bundle.zip).Length
$asSecret = [math]::Ceiling($raw * 4 / 3)
Write-Host "raw=$raw b64=$asSecret limit=49152"
```

- `b64 <= 49152`: one secret `TG_SESSION_B64` = base64 of the zip. Done.
- Larger: split the BASE64 TEXT into <=48 KB chunks `TG_SESSION_B64_1..N`
  (concatenated in order = the same text) and record N. Do NOT re-zip per chunk.
- If even the raw session exceeds a few hundred KB, stop and rotate: the
  account picked up unexpected state; use a fresh dedicated account instead of
  stuffing megabytes of credential-adjacent data into secrets.

## 3. Secrets to set (repo Settings > Secrets and variables > Actions)

| Secret | Value | Notes |
|---|---|---|
| `TG_API_KEY` | REST key plaintext | Only its SHA-256 ever lands on disk |
| `TG_SESSION_B64[_N]` | base64 session zip (or chunks) | Live credential; dedicated account only |

## 4. What the runner does with them (already implemented, no secrets in repo)

`Enable-TelegramRest.ps1` reads `TG_API_KEY` + `TG_SESSION_DIR` from process env,
places ONLY allowlisted filenames (`telegram.session*`, `config.json`), writes
`api_settings.json` with the key hash, launches the app, polls `/health`, then
probes one authenticated call reporting only the status code (`SIGNED-IN` =
HTTP 200; `SIGNED-OUT` = HTTP 503 `NOT_CONNECTED`). Bodies are never printed.
A decode step (base64 secret -> `TG_SESSION_DIR`) is added to the workflow only
when these secrets exist, and the first run with them is the decisive
publish -> download -> hash-verify -> Runner-A-destroy -> Runner-B-restore test
on synthetic data.

## 5. Clean-copy restore test (before depending on the bundle)

After setting the secrets, the acceptance run restores the bundle into a FRESH
app-data dir (never merges into an existing install) and must report
`TELEGRAM|REST=UP|SESSION=SIGNED-IN`. If it reports anything else, the bundle
is stale/corrupt: re-export from the signed-in machine (app closed) and rotate.
