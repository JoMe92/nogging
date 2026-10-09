## 1. Implementation and validation

- [x] TASK-WSS-001 Introduce a canonical repository state/lock resolver used by discovery acknowledgement and worktree-aware guards; verify main checkout, relative and absolute common-dir, spaces, linked worktrees and unsupported/non-Git paths without changing unrelated state locations.

- [x] TASK-WSS-002 Migrate and atomically merge legacy acknowledgement ledgers with concurrent-addition protection and recovery backup; verify acknowledgement from two worktrees, interrupted writes and clean worktree retirement preserve every ID and user-readable review behavior.

- [ ] TASK-WSS-003 Fix Pi OpenSpec authorization to require canonical fresh planning lock, absent sentinel and planning role; verify no lock, stale/malformed lock, unreadable state, non-Git cwd, closed main sentinel and execution role all deny, while authorized planning permits writes.

- [ ] TASK-WSS-004 Update doctor, failure-recovery and Pi guidance with canonical state and fail-closed behavior; verify TTL override, path normalization and guard activation from a fresh supervised linked worktree with no standing trust mutation.

- [ ] TASK-WSS-005 Run scripts/test and a scratch linked-worktree acknowledgement/guard integration check; record #48/#55 evidence including negative execution-write cases while a separate planning lock is open.

## Execution contract

Every task is claimed by the Main Worker and implemented only in its own allocated worktree. Before starting a dependent change, verify the prerequisite branch is integrated into develop. Relevant checks precede closure; run bd close, immediately scripts/nogg task-done, then commit the execution change and mapped tick together with the real Bead ID, and append SHA/evidence. Only the task-done mechanism may tick the mapped task during execution; agents do not hand-edit OpenSpec. Discoveries carry the discovery label and prose; no automatic GitHub issue closure or human sign-off.
