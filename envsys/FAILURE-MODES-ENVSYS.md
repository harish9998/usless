# ENVSYS failure modes (no false greens anywhere)

| Failure | Detection | Behavior |
|---|---|---|
| Upload interrupted | size verify after upload | latest untouched, previous stays live |
| Corrupt latest (bytes flipped) | manifest digest mismatch | restore refuses; use previous (retention keeps it) |
| Size drift | file count/bytes compare | reject snapshot |
| Secret in staging | `Protect-SnapshotSecrets` exit 2 | publish aborted, nothing uploaded |
| Secret-named env var | name-pattern redaction | placeholder stored, value never lands |
| App install impossible | manifest health gate exit 1 | no READY emitted |
| Restore component error | per-component FAIL + exit 1 | DEGRADED reported, workspace state explicit |
| Power/registry need admin | exit-code-checked native calls | clean FAIL message, not a crash |
| Telegram app down/key bad | curl exit codes + retries + fail | clean throw after 4 tries, job continues degraded |
| Duplicate watcher | exclusive file lock | second instance stands down |
| Native stderr-success (`reg import`) | `Invoke-Native` exit-code checks | success recognized, no false FAIL |
| 8.3 short-path mangling | same-API base normalization | relative paths correct on all hosts |
| Missing Get-FileHash | .NET hashing everywhere | works on stripped hosts |
| Machine-unparseable status | stdout API rule | all phases emit `COMPONENT/STATUS` lines |

Invariant: **a runner is READY only if required phases report SUCCESS.**
Degraded states are named (`DEGRADED-n`, `SKIP-reason`), never silent.
