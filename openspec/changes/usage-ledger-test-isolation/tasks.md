## 1. Ledger compatibility (fix/ lane, sequential)

- [ ] TASK-ULT-001 [complex] Implement tolerant ledger decoding, stable accounting validation and opaque-entry preservation per design Decisions 1-2; read both legacy shapes and version 1, count future entries without probes, fail safely on invalid accounting. Check: new scripts/usage-ledger-schema.test.sh, existing usage-reservations.test.sh and usage-gate.test.sh, scripts/test. Branch: fix/usage-ledger-test-isolation. No dependency.

- [ ] TASK-ULT-002 [standard] Stamp pending/bound entries with schema_version 1, preserve extensions and refuse opaque-target bind/release per design Decisions 1-2. Check: new scripts/usage-ledger-writers.test.sh (pending/bound lifecycle, opaque targets, failure cleanup), usage-reservations.test.sh, scripts/test. Branch: fix/usage-ledger-test-isolation. Depends on TASK-ULT-001.

## 2. Test bootstrap (independent refactor/ lane)

- [ ] TASK-ULT-003 [standard] Add shared scripts/lib/test-env.sh and replace scripts/test's fixed list per design Decision 3; clear exported NOGG_* plus NOGGING_ROOT before fixtures, preserve parent/unrelated settings and ship helper where needed. Check: new scripts/test-environment.test.sh (future names, strict-shell, nested cleanup, parent preservation), package checks, scripts/test. Branch: refactor/usage-ledger-test-isolation. No dependency.

## 3. Direct entry points (test/ and chore/ lanes, parallel)

- [ ] TASK-ULT-004 [standard] Isolate the shell planning/Claude test group and report all three nogg.test.sh planning setup failures by name per design Decision 4. Check: new scripts/direct-planning-isolation.test.sh (actual direct suites, poisoned context, zero broker contacts, forced setup failure), scripts/test. Branch: test/usage-ledger-test-isolation. Depends on TASK-ULT-003.

- [ ] TASK-ULT-005 [standard] Isolate Python/Pi/Antigravity guard test entries before imports and audit every test/harness for remaining planning/guard calls per design Decision 4; record inventory. Check: new scripts/direct-guard-isolation.test.sh (actual direct suites, poisoned context, zero broker contacts, explicit fixture authority), scripts/test. Branch: chore/usage-ledger-test-isolation. Depends on TASK-ULT-003.

## 4. Mixed-version integration and guidance

- [ ] TASK-ULT-006 [standard] Verify mixed ledger readers/writers and installed payload per design Decision 5; add labelled v2.2.0 negative fixture and extend packed-usage-gate.test.sh. Check: new scripts/usage-ledger-compatibility.test.sh (future preservation, readonly bytes, invalid core, atomic final slot), packed-usage-gate.test.sh, scripts/test. Branch: feat/usage-ledger-test-isolation. Depends on TASK-ULT-002 and TASK-ULT-003.

- [ ] TASK-ULT-007 [routine] Document the tolerant-reader update floor, safe rollback/recovery and direct-test isolation in session/recovery guides per design Migration Plan; no release or live ledger changes. Check: guidance matches implemented diagnostics, links resolve, final entry-point inventory reviewed, installation-docs.test.sh and scripts/test pass. Branch: docs/usage-ledger-test-isolation. Depends on TASK-ULT-004, TASK-ULT-005 and TASK-ULT-006.

## Dependency contract

Materialize explicit Beads edges (`child <- blocker`): 002<-001;
004<-003; 005<-003; 006<-002; 006<-003; 007<-004; 007<-005;
007<-006. No cross-change dependency is required. Task order and change
association create no implicit blocking edges. Branch prefixes and file
ownership are defined in design.md; same-prefix tasks are sequential.

## Execution contract

Every task includes design Decision 6 and its mapped capability scenarios.
Only the Main Worker claims execution Beads, allocates isolated worktrees,
validates, closes and immediately runs task-done, commits implementation plus
the mechanical tick with its Bead-ID token, and records SHA/evidence, following
AGENTS.md and current operator delivery authority. Execution agents do not
hand-edit OpenSpec. Verify prerequisite commits are integrated into develop
before allocating dependent worktrees. All tasks suit Codex/Antigravity Leads.
Planning itself authorizes no implementation, push, release or human sign-off.
