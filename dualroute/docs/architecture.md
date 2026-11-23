# DualRoute AI — implemented system

## What it is
A model-independent, free-first routing layer for OpenCode. Logical roles stay stable while actual model IDs change. Live catalog from `opencode models` (135 models, 61 free at last refresh) + config pricing/capability metadata.

## Current role assignments (from registry/catalog.json)
- `default_economy` → `opencode/hy4-flash-free` (your initial default)
- `preferred_free_specialist` → `opencode/deepseek-v4.1-flash-free` (your preferred specialist — verified live)
- `best_free_coding` / `best_free_reasoning` → best available free by context/reasoning
- `optional_paid_specialist` → disabled (paid never selected)

## Agents installed
- `dualroute-economy` (primary): classifies by CONTENT signals, executes routine work, delegates hard work.
- `dualroute-specialist` (subagent): free specialist, compact handoff format.
- `rdp-efficient` (subagent): routes hard tasks to the RDP runner's **fresh DeepSeek quota** via the permanent bridge when local DeepSeek is exhausted.

## Files
```
dualroute/config/routing.json     model preferences, routing map, cost policy
dualroute/registry/catalog.json   discovered models + resolved roles (live)
dualroute/registry/health.json    unhealthy/rate-limited model state
dualroute/scripts/discover.ps1    live discovery + role resolution
dualroute/scripts/route.ps1       task classifier + selector
dualroute/scripts/health.ps1      mark/recover/list model health
dualroute/scripts/track.ps1       usage JSONL + summary
dualroute/scripts/refresh.ps1     safe refresh (restores previous on failure)
dualroute/tests/Run-DualRouteTests.ps1  10 offline tests
~/.config/opencode/agent/*.md     3 installed agents
~/.config/opencode/command/models-refresh.md
```

## Commands
```powershell
powershell -File dualroute/scripts/discover.ps1                  # refresh catalog
powershell -File dualroute/scripts/route.ps1 -Task "debug race"  # see routing decision
powershell -File dualroute/scripts/health.ps1 -Action mark -ModelId <id> -Reason ratelimited
powershell -File dualroute/scripts/health.ps1 -Action recover -ModelId <id>
powershell -File dualroute/scripts/track.ps1 -Action summary
/models-refresh   (in OpenCode)
```
In OpenCode: select agent `dualroute-economy` as primary. Difficult work auto-delegates to `dualroute-specialist`; if local DeepSeek is exhausted, use `rdp-efficient`.

## Changing preferences WITHOUT changing architecture
Edit only `dualroute/config/routing.json`:
- `roles.<role>.preferredIds` — ordered preferred model IDs (the system falls back to best-free if all are unavailable).
- `policy.allowPaid` — set `true` ONLY with explicit opt-in; paid role stays disabled otherwise.
- `routing` — map difficulty classes to roles.
- `health.*TtlMinutes`, `maxRetries`, `maxDelegations` — safety limits.
Model IDs are never hardcoded in agents or route logic — they always read from the catalog.

## Cost protection
FREE-first enforced at 3 layers: discovery marks free/paid from pricing metadata; role resolution excludes paid roles unless enabled; route.ps1 re-checks the selected model's free flag and falls back if paid while `allowPaid=false`.

## Honest limitations
- Built-in `opencode/*` models have no local pricing metadata — inferred free from the `-free` suffix/`opencode` provider; verify in your account before heavy use.
- Real benchmark evaluation (repo understanding, tool-call reliability) is scaffolded in `dualroute/benchmarks/` but requires actual LLM calls; not run automatically.
- Catalog includes 13 configured-live + inferred models; 61 free total.
