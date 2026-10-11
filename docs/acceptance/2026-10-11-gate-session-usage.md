# Gate session usage — scoped execution evidence — 2026-10-11

This unsigned report covers `gate-session-usage`, TASK-GSU-006 (`SPEC-6ajx`),
resolving issue #53. It records scoped implementation checks and execution
evidence; it does not provide human acceptance sign-off or public release
authorization.

## Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-10-11 |
| Host platform | Linux aarch64 (`raspberrypi`) |
| Executor | Nogging Lead (supervised session) |
| Implementation baseline | `a8cb797` (develop after PR #121, TASK-TUC-007) |
| Prerequisite commits | TASK-GSU-001 through TASK-GSU-005 integrated in develop |
| Package metadata | `nogg` 2.1.0; unreleased checkout, not a new published tag |
| Node / npm | v22.23.2 / 10.9.8 |
| Python / Git | 3.13.5 / 2.47.3 |
| Bash / tmux | 5.2.37 / 3.5a |
| Available Agent runtimes | Claude Code 2.1.296, Codex CLI 0.162.1, Pi 0.85.0, Antigravity 1.3.3 |
| Distribution path | `npm pack --ignore-scripts`, extract archive, run packaged `bin/cli.js` |

## Issue #53 scope and capabilities

Issue #53 addresses shared account exhaustion caused by uncoordinated parallel
worker sessions. The `gate-session-usage` change introduces:
1. Normalized quota inspection across short (5-hour / 300-minute) and weekly
   (7-day / 10080-minute) windows for Codex and Claude Code.
2. Atomic pre-launch admission gate (`exit 75` on denial) evaluated before any
   worktree allocation, trust modifications, tmux creation, or session record
   writing.
3. Same-host reservation coordination via an owner-only user-cache ledger
   (`$XDG_CACHE_HOME/nogging/usage/reservations/ledger.json`) with kernel lock
   serialization, stale-owner cleanup, and lifecycle release.
4. Model-aware bounded learned estimates collected from isolated, non-reset
   intervals with conservative fallbacks.
5. Opt-in statusline capture composition for Claude Code and `doctor`
   freshness diagnostics.

## Package payload & consumer lifecycle

Verified in `scripts/packed-usage-gate.test.sh`:

| Check | Result | Evidence |
| --- | --- | --- |
| Archive payload | pass | `npm pack --ignore-scripts` includes `scripts/nogg_usage.py` and omits test files (`*_test.py`) and bytecode (`__pycache__`, `*.pyc`). |
| Consumer `init` | pass | `cli.js init` installs `scripts/nogg_usage.py` with identical content to packaged helper. |
| Consumer `update` | pass | `cli.js update` repairs modified/corrupted `scripts/nogg_usage.py` while preserving user `.nogging/config.json`. |
| Consumer `remove` | pass | `cli.js remove` deletes `scripts/nogg_usage.py` while retaining user `.nogging/config.json`. |

## Packed installed-consumer admission & concurrent race

All scenarios below were exercised against the packaged consumer payload in
`scripts/packed-usage-gate.test.sh`:

| Scenario | Result | Evidence |
| --- | --- | --- |
| Read-only text usage | pass | `nogg usage --agent codex` reports `short: 87% used`, `weekly: 40% used`, `fits: yes`. |
| Read-only JSON usage | pass | `nogg usage --agent codex --json` returns schema v1 with windows and gate projection. |
| Missing/unknown usage | pass | Reports `unknown (missing usage source)` without fabricating zero usage. |
| Fitting launch admission | pass | 87% used + 5% estimate = 92% <= cap (92%); launch admitted, reservation token created in ledger. |
| Ledger lifecycle release | pass | Stopping and cleaning up session releases reservation token from cache ledger. |
| Over-cap denial (short) | pass | 88% used + 5% estimate = 93% > 92%; exits 75, names limiting reset, leaves zero session records or settings files. |
| Size label scaling | pass | `size:large` scales estimate to 10%; 85% + 10% = 95% > 92%; exits 75 with denial output naming 10% estimate. |
| Config `on_unknown: deny` | pass | Missing/stale source with `on_unknown: deny` exits 75 without side effects. |
| `--ignore-usage-gate` | pass | Bypasses admission check and records `usage_gate.decision: "ignored"` on session record. |
| Excluded roles | pass | Launch with `exclude_roles: ["lead"]` records `usage_gate.decision: "excluded"`. |
| Concurrent final slot race | pass | Two concurrent processes competing for a single remaining 5% slot: exactly one admits (exit 0) and one is denied (exit 75). |

## Read-only live quota observation

Executed on the live host checkout without side effects:

```
$ ./scripts/nogg usage --agent claude
claude usage (account and model-group identity unknown)
  short: unknown (missing usage source)
  weekly: unknown (missing usage source)
  estimate 5% per launch; reserved 0%; fits: unknown

$ ./scripts/nogg usage --agent codex
codex usage (account and model-group identity unknown)
  short: unknown (stale observation)
  weekly: unknown (stale observation)
  estimate 5% per launch; reserved 0%; fits: unknown

$ ./scripts/nogg doctor
...
NOTE  quota observation (claude): missing statusline cache — run `nogg usage install-statusline` to opt in
NOTE  quota observation (codex): observation is stale (> 600s old) — run Codex to refresh
```

Findings:
- Live inspection correctly reports status as `unknown` rather than defaulting
  to zero usage.
- Claude reports missing statusline cache, and `doctor` suggests opting in via
  `nogg usage install-statusline`.
- Codex rollout event is older than 600 seconds, correctly identified as
  `stale observation` (> 600s).

## Authorized single scratch launch evidence

A single authorized scratch launch was executed on the host under session
`sf-lead-spec-6ajx-20261011t155051-b674`:
- Launch evaluated against live host usage sources; with unconfigured Claude
  statusline cache, gate resolved `decision: "unknown-admitted"`.
- Reservation `0e50ece793354f00af9811c0c35dde03` was bound in the cache ledger
  during the run.
- Completed with exit reason `"acceptance scratch probe completed"`.
- Session stop and retirement cleanly released reservation from the ledger.

## Same-host scope and estimation limits

1. **Same-host ledger scope**:
   - The admission ledger coordinates quota reservations across all worktrees
     and repositories on the same host sharing `$XDG_CACHE_HOME`.
   - Adapters currently lack account and model-group identifiers, so reservations
     are grouped conservatively under an opaque scope per provider for the OS
     user.
2. **Multi-machine / cross-host boundary**:
   - Cross-host admission coordination is **unsupported in v1**, even when
     `multi_machine: true` is configured in `.nogging/config.json`.
   - External machines or non-Nogging processes spending account quota are not
     tracked by the local ledger and are visible only after local observation
     snapshots update.
3. **Estimation limits**:
   - A gate admission reduces concurrent exhaustion risk but does not guarantee
     that a task fits within quota.
   - Ongoing sessions may already have consumed part of the current `used`
     metric; reserved estimates remain conservative rather than additive.

## Validation results

| Check | Result | Evidence |
| --- | --- | --- |
| Full script test suite | pass | `./scripts/test` passes 86 of 86 tests (`Nogging: all script tests passed`). |
| Packed usage gate suite | pass | `bash scripts/packed-usage-gate.test.sh` passes all packaging, CLI, admission, and lifecycle tests. |
| Documentation coverage | pass | `docs/running-work-in-sessions.md` documents same-host scope and cross-host coordination limits. |

## Sign-off

Signed-off-by:
