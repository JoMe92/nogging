# Shared worktree state — scoped execution evidence — 2026-10-09

This unsigned report covers `harden-worktree-shared-state`, TASK-WSS-005
(`SPEC-6t8i`), issues #48 and #55. It records scoped implementation checks;
it does not provide human acceptance or a public release sign-off.

| Field | Value |
| --- | --- |
| Executor | Nogging Lead |
| Implementation baseline | `52378eb` |
| Implementation commits | `21600a0`, `b1dcb39`, `10eb4eb`, `52378eb` |
| Environment | Linux aarch64; Node 22.23.2; local Git and tmux |
| Runtime evidence | Installed Pi, offline, no model request; other session paths use stub runtimes |
| Distribution evidence | Normal package installer and packed fresh/update consumers |

The repository-state regression resolves the canonical main checkout from
ordinary and linked worktrees, nested directories and paths with trailing
spaces. It covers older Git's relative common-directory result, `.git`
indirection, unavailable metadata, bare repositories and explicitly unsupported
separate-Git-directory layouts. Merely resolving state creates no directories.
Only planning boundary and discovery acknowledgement state are shared; session,
allocation, report and other lock locations retain their previous scope.

The discovery regression preserves legacy and canonical acknowledgement IDs,
retains conservative timestamps, stores recovery snapshots, and exercises 16
concurrent writers across three checkouts. An interrupted replacement leaves
previous bytes intact. Malformed ledgers refuse to overwrite valid state.
After retirement of the acknowledging worktree, surviving checkouts still omit
acknowledged discoveries; closed unacknowledged discoveries remain visible and
blocking discoveries remain first. Human notes remain readable.

The Pi boundary regression denies missing, stale, malformed, unreadable and
future lock state, invalid configuration, unsupported Git resolution, canonical
and legacy closed sentinels, and dangling sentinel symlinks. TTL overrides,
nested cwd, `..`, absolute paths and existing symlinks are covered. Explicit
planning is permitted only with fresh canonical authority. Lead, specialist,
orchestrator and absent role context deny OpenSpec writes during planning.
Ordinary implementation edits remain permitted when their scope is established.

The actual installed Pi loader was exercised through `scripts/session-launch`
in a fresh scratch linked worktree with an isolated agent configuration. The
wrapper explicitly loads the guard, the guard blocks execution OpenSpec writes
and command-floor matches, and missing guard payload refuses startup. No
standing `trust.json` was created. This check does not ask a model to generate a
tool call and does not claim an OS sandbox: Pi remains floor-only at both
Nogging authority levels.

A separate combined scratch check opened a planning lock in one worktree,
acknowledged discoveries there, merged a legacy ledger from another worktree,
and invoked write/edit guard calls from execution roles while planning remained
open. Those execution calls were denied; explicit planning was permitted. The
planning worktree was then safely removed. Both surviving checkouts retained
all acknowledgement IDs, and the canonical lock remained available for
`plan-end` from the main checkout to restore the closed sentinel.

| Validation | Result / reproducible entry point |
| --- | --- |
| Canonical resolver | pass — `bash scripts/repository-state.test.sh` |
| Discovery durability/concurrency | pass — `bash scripts/discovery-acknowledgements.test.sh` |
| Pi boundary/TTL/path/roles | pass — `bash scripts/pi-planning-boundary.test.sh` |
| Pi command floor | pass — `bash scripts/pi-guard.test.sh` |
| Actual installed Pi wrapper/loader | pass — `bash scripts/pi-live-guard.test.sh` (explicit skip when Pi unavailable) |
| Combined scratch integration | pass — execution log `/tmp/nogging-6t8i-integration.log`; details above |
| Strict scoped OpenSpec validation | pass — `openspec validate harden-worktree-shared-state --strict` |
| Complete source and installed-consumer suite | pass — `bash scripts/test`: all script tests passed |

The full-suite log for this run is `/tmp/nogging-6t8i-tests.log`. Temporary logs
are host-local diagnostic evidence; the checked-in tests and scenario details
above provide the durable reproduction path. The human sign-off remains open.

Signed-off-by:
