## Context

See proposal.md for sources #163/#164. Research used develop b73fc1f;
planning rebased to 3a415ae. The intervening commits did not change
`nogg_usage.py`, `scripts/test` or `nogg.test.sh`.

The reservation ledger is one token-to-entry JSON map under
`${XDG_CACHE_HOME:-~/.cache}/nogging/usage/reservations/ledger.json`.
`_transaction()` checks every entry's liveness before filtering its scope.
`bind()` writes `{path,name,probe:{backend,argv}}`; `_alive()` understands
this and the legacy `{path,name,tmux,socket}` shape, but not arbitrary future
or malformed shapes. No entry version exists. An isolated replay of
v2.2.0's reader raised `KeyError: 'tmux'` on the current probe shape.

`scripts/test` clears a fixed list, but direct test entry points do not.
Three bare planning setup calls in `nogg.test.sh` abort under `set -e`.
Existing discoveries SPEC-93hk, SPEC-9txl, SPEC-9085 and SPEC-tbqa document
the inherited role, fence, root and task-broker contamination. Their other
findings remain outside this change; no whole-Bead acknowledgement is implied.

## Goals / Non-Goals

Provide stable shared accounting and a documented compatibility floor. Make
direct planning/guard test execution independent of the caller's authority.
Keep production guard rules, the runtime fence and parent session context
unchanged. Do not retrofit an immutable tag or claim unpatched v2.2.0 support.

## Decisions

### 1. One ledger with an entry version and stable accounting core (ULT-001/002)

Keep the file path, top-level token map, advisory lock inode, owner file
locks and atomic replacement. New pending entries carry integer
`schema_version: 1`; binding retains that version. Missing version means
legacy, not version zero; both existing unversioned session shapes remain
readable. Do not introduce a header that an old token-map reader mistakes
for a reservation, or a version-specific path that undercounts other releases.

Across entry versions retain this accounting core: nonempty string `scope`,
finite nonnegative numeric `estimate` (not boolean), dictionary `windows`
whose reset values are valid timestamps or null, and a nonempty safe owner
file basename in `owner`. Preserve reset-window matching, including null,
exactly as today. Validate the entire ledger's accounting before any probe,
action or rewrite; do not silently skip another scope's corrupt entry.
Reject malformed top-level data or unusable accounting with a controlled
ledger diagnostic and nonzero status before launch side effects. Existing
quota denial remains exit 75. Never convert unreadable reservations to zero
or let `on_unknown=warn` erase accounting errors.

ULT-001 owns decoding/validation, `_alive`, `_totals` and transaction
preservation. ULT-002 owns stamping new pending entries and the bind/release
mutation checks. The same-module edits are sequential.

### 2. Understood liveness only; opaque entries are retained (ULT-001/002)

Classify version and session shape before I/O. A positive integer version
greater than 1, an invalid explicit version, or malformed session metadata
with a usable accounting core is opaque. Count it in matching scope/windows,
preserve its complete decoded JSON value and unknown fields on unrelated
transactions, and issue a concise unsupported/malformed-entry diagnostic.
Never execute its probe, inspect its record, take its owner lock as proof of
death, or reap it, even if a record appears terminal. A missing session field
on an understood entry is the supported pending-owner form; an invalid
session value is not silently converted to pending.

For understood legacy/version-1 entries retain the current live/absent/unknown
probe semantics and terminal-record handling. Probe argv and legacy fields
must be well formed before use. Tool absence, timeout, unexpected exit or
malformed record are not proof of death. Catch shape/type errors narrowly;
do not swallow arbitrary I/O or programming failures as successful admission.

`bind` and `release` refuse attempts to alter an opaque target with a clear
diagnostic; another token's valid mutation still preserves opaque entries.
An understood entry retains extensions when bound or released normally.
Read-only totals never rewrite/reap or create files. Conservative retention
can reserve headroom longer; that is preferable to admitting excess workers.

### 3. Generic test environment bootstrap (ULT-003)

Add source-only `scripts/lib/test-env.sh`. Sourcing it removes every exported
variable whose name starts with `NOGG_`, plus `NOGGING_ROOT`, in that test
process. Enumerate names without printing values or using `eval`; operate
under `set -euo pipefail`, including an empty match set. It is idempotent.
No fixed allow/deny list of session variables is acceptable. Preserve
unrelated variables, including test-runner quota fixtures and npm cache
settings. Tests needing `HERDR_*`, `TMUX` or `TMUX_TMPDIR` isolation continue
to clear those as their fixture requires.

Source it at the start of `scripts/test`, replacing its fixed list, and in
each affected direct test entry before imports, fixture setup or children.
Source again safely in nested test entry points. Fixtures set their own
`NOGG_*` values only afterwards. Do not sanitize the invoking operator shell,
production commands or live session environment. Keep helper and dependent
tests available together in any shipped payload; inspect `bin/lib/manifest.js`
and package tests, and adjust only if packaging actually ships those tests.

`scripts/test-environment.test.sh` verifies arbitrary future `NOGG_` names,
all exported session/fence/broker context, unrelated-variable preservation,
idempotence, empty input and the parent shell's unchanged environment. Test
the real bootstrap in child shells, not a duplicated implementation.

### 4. Complete direct-entry coverage and named setup failures (ULT-004/005)

ULT-004 owns the shell planning/Claude group: `scripts/nogg.test.sh`,
`agents-boundary.test.sh`, `acceptance.test.sh` and the mechanical acceptance
callee if needed. Guard all three bare `plan-begin` setup calls (baseline
lines 902, 987, 1071): report the scenario and failure output, set failure
status, and skip dependent assertions or exit with that named failure. A
failed setup must never be silently ignored or reported as success.

ULT-005 owns Python/Pi/Antigravity entry points: `repository-state.test.sh`,
`planning-kickoff.test.sh`, `pi-guard.test.sh`, `pi-planning-boundary.test.sh`,
`pi-live-guard.test.sh`, `agy-guard.test.sh` and
`antigravity-launch.test.sh`. Earlier child-only scrubbing is useful but
does not replace cleaning before a module reads environment at import.

Audit every `scripts/**/*.test.sh` and any harness/helper it invokes for
actual planning-command or OpenSpec-guard execution. Pure text checks and
copy-only installer tests do not need edits solely because a path matches.
ULT-005 records the final inventory in its Bead evidence. New matches outside
ULT-004's file group belong to ULT-005. This includes newly integrated suites,
without changing another active task's behavioral expectations.

Each group adds one regression wrapper, respectively
`scripts/direct-planning-isolation.test.sh` and
`scripts/direct-guard-isolation.test.sh`. Run its actual selected entry
points directly in a child environment poisoned with role-only, name-only
and combined contexts, arbitrary unknown `NOGG_` names, bad roots and fence
markers. Use an isolated temporary quota source and npm cache. Inject a
listening broker sentinel and assert zero connections/requests, including
`nogg.test.sh` task-done fixtures. Intentionally supplied fixture session
context must still exercise role and ownership refusals. Do not recursively
invoke `scripts/test` from these wrappers. Supported optional runtimes keep
their existing explicit skips; required shell/Python coverage never skips.

### 5. Compatibility and delivery evidence (ULT-006)

Add `scripts/usage-ledger-compatibility.test.sh`: exercise unversioned tmux,
unversioned backend-neutral, version 1 pending/bound, future and malformed
session shapes with valid core, and invalid accounting. Verify totals,
scope/reset behavior, unchanged read-only bytes, opaque preservation across
admit/bind/release, refused opaque-target mutation, and atomic concurrent
final-slot admission under the existing common lock. Include unknown fields
and terminal-looking opaque entries. A probe stub records that opaque data
never executes anything; no live session is needed.

Keep a small labelled, source-attributed v2.2.0 reader fixture showing the
original failure. It is a negative compatibility case, not the supported
reader. Replay legacy and new writers against the patched reader; future
version cases demonstrate this release acting as an older tolerant reader.
Do not fetch a tag or install an old release during tests.

Extend the existing packed usage regression to verify the installed helper
writes versions and reads mixed entries without lost accounting. ULT-006 owns
this packed test; it does not change the shipping version or publish anything.

### 6. Test discipline and validation (every task)

All new or changed regression paths are offline and run on GitHub runners:
no real Dolt/`bd`, no PID-range constants, no `unshare` or sandbox supervision,
no existing tmux/herdr server. Stub backends/commands and quota sources. Where
liveness needs a process use a child that is kept alive or explicitly reaped;
inject namespace facts. Broker sentinels use short `/tmp/nogg.XXXXXX` paths
and assert the complete socket path is shorter than 108 bytes. Bound waits
and reap children in cleanup. Never contact live quota sources, broker or
session services. The real broker address is discarded before fixtures run.

Every task runs its named meaningful check and `scripts/test`, using a
temporary npm cache if the host cache is unwritable. Capture clear failures
without credentials. Regression wrappers execute real entry points; they
must not lint solely for a `source` line or mirror the scrub implementation.
ULT-007 checks final documentation and the assembled test inventory.

## Dependencies and parallel lanes

Branches use `<prefix>/usage-ledger-test-isolation`. A lane reuses its branch
only after its predecessor is integrated and the old branch is safely retired.
The prefix distinguishes concurrent worktrees, not the commit's semantic type.

| Task | Complexity | Depends on | Branch prefix | Owned files |
| --- | --- | --- | --- | --- |
| ULT-001 tolerant reader | complex | none | `fix/` | nogg_usage.py reader/transaction/totals; new usage-ledger-schema.test.sh |
| ULT-002 versioned writer | standard | 001 | `fix/` | nogg_usage.py admit/bind/release; new usage-ledger-writers.test.sh |
| ULT-003 generic bootstrap | standard | none | `refactor/` | scripts/lib/test-env.sh, scripts/test, packaging if needed; new test-environment.test.sh |
| ULT-004 shell entry points | standard | 003 | `test/` | shell group in Decision 4; new direct-planning-isolation.test.sh |
| ULT-005 other guard entry points | standard | 003 | `chore/` | other group/audit in Decision 4; new direct-guard-isolation.test.sh |
| ULT-006 compatibility matrix | standard | 002, 003 | `feat/` | new usage-ledger-compatibility.test.sh, labelled reader fixture, packed-usage-gate.test.sh |
| ULT-007 operator docs | routine | 004, 005, 006 | `docs/` | docs/running-work-in-sessions.md, docs/failure-recovery.md |

Explicit edges (`child <- blocker`): 002<-001; 004<-003; 005<-003;
006<-002; 006<-003; 007<-004; 007<-005; 007<-006.
001 and 003 can start in parallel; 004 and 005 can then run in parallel.
006 needs the new writer and bootstrap; docs describe all integrated results.
Before allocating a dependent worktree, verify prerequisites are integrated
into develop, not merely closed. Every implementation task suits an isolated
Codex or Antigravity Lead. No live acceptance task or extra host authority
is needed for these deterministic compatibility/environment contracts.

HSS-002 (SPEC-wwio) is integrated at a8ce4c5. HSS-005 (SPEC-culj) still owns
nudge; HSS-007/008 own supervision docs/acceptance. The new
`reliable-session-input` and `relaunch-on-orchestrator-restart` changes own
different regions of `scripts/nogg`. This change does not edit that runtime
file or backend modules, and requires no cross-change blocking edges.
ULT-007 edits only ledger/test-isolation sections; rebase for concurrent docs.
No dependencies are inferred from change association or Markdown order.

## Risks / Trade-offs

- Opaque entries can retain headroom indefinitely. Explain the diagnostic and
  update the owning reader/writer; never delete a live reservation as a fix.
- Unpatched releases ignore versions and may crash or reap an entry. The
  supported coexistence floor is a tolerant patched reader in every consumer;
  adding a marker alone cannot provide that guarantee.
- Broad test cleanup removes future fixture knobs. Opt in after bootstrap,
  and prove the parent retains its production identity and broker.
- Direct-entry regressions add runtime. Keep suites grouped, bounded and
  nonrecursive, and reserve a full-suite run for each task's final validation.

## Migration Plan

No eager rewrite of the live host ledger. Read existing entries in place;
stamp new entries only and preserve extensions on binding. Documentation
explains upgrading every older consumer to a release containing this fix
before relying on mixed-version operation; preparing/releasing such a patch
is outside this change. No bypass flag is a permanent accounting solution.

Rollback to a tolerant reader that supports the retained accounting core.
Downgrading directly to unpatched v2.2.0 beside newer live sessions remains
unsupported; wait for owners to finish or update the consumers. Never split
the ledger, hand-edit reservations or stop operator sessions automatically.
