# ENVSYS security

## Never in snapshots (enforced in code, not just docs)

`.credentials.json`, `auth.json`, `.env`, `*.key`, `*token*.json`,
`credentials*.json`, plus content patterns: private keys, `ghp_/gho_/github_pat_`,
`AKIA`, `xox[bap]-`, `tskey-auth-`, `sk-ant-`, `sk-`, `AIza`, `glpat-`.
Environment variables whose names match `*TOKEN* *SECRET* *PASSWORD* *API_KEY*
`etc. are stored as `{{SECRET:NAME}}` placeholders, never values.

## Gates (fail-closed)

1. Capture excludes secret-named files from manifests (workspace + robocopy `/XF`).
2. `Protect-SnapshotSecrets` scans the staged tree; exit 2 aborts publish.
   Proven: caught a real `GITHUB_PERSONAL_ACCESS_TOKEN` on the dev box.
3. Publish never advances `latest` until the new snapshot verifies.

## Channels

- Secrets travel only via: GitHub Secrets > env vars > `{{SECRET:NAME}}` injection
  at restore time. Placeholders are never written back literally.
- Telegram REST: API key via `$env:TG_API_KEY` (process env only); loopback HTTP
  (never leaves the box); app stores no plaintext tokens.
- No secrets in: logs (values masked as `***` by Actions), snapshots, reports,
  commits, archives.

## Runner account hardening (apply on long-lived boxes)

- Dedicated least-privilege sync account, key-only SSH, no password auth.
- Restrict to its directory; separate credentials from agents/OpenClaw.
- A compromised runner must never yield VPS/root or secret material:
  snapshots contain zero secrets by construction, so theft gains no credentials.
