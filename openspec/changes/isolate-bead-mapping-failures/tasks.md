## 1. Implementation and validation

- [x] TASK-BMF-001 Define and implement mapped/follow-up/unmapped classification with typed scoped diagnostics; verify valid pairs, change-only malformed labels, explicit follow-ups, inherited duplicate labels and illegal follow-up-plus-task combinations.

- [x] TASK-BMF-002 Scope materialize target validation and sync reconciliation plans by affected change while keeping audit strict; verify malformed change A does not prevent materialize/mirror B and global ambiguity still refuses all writes.

- [x] TASK-BMF-003 Exclude non-task follow-ups from checkbox mirroring and account for explicit blocking dependency edges in completion/archive readiness; verify no fabricated task, no duplicate Bead and no premature complete classification.

- [x] TASK-BMF-004 Persist partial-pass health, complete-success timestamp and per-change failures with a documented degraded exit; verify repeated partial passes are idempotent, repaired mappings clear scoped diagnostics, and doctor names IDs, reasons and age.

- [ ] TASK-BMF-005 Document sanctioned follow-up creation and manual repair without dropping traceability; run scripts/test and a two-change real/stub tracker integration fixture covering malformed, repaired and independently completed work.

## Execution contract

Every task is claimed by the Main Worker and implemented only in its own allocated worktree. Before starting a dependent change, verify the prerequisite branch is integrated into develop. Relevant checks precede closure; run bd close, immediately scripts/nogg task-done, then commit the execution change and mapped tick together with the real Bead ID, and append SHA/evidence. Only the task-done mechanism may tick the mapped task during execution; agents do not hand-edit OpenSpec. Discoveries carry the discovery label and prose; no automatic GitHub issue closure or human sign-off.
