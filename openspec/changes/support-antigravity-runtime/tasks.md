## 1. Implementation and validation

- [x] TASK-AGR-001 Revalidate agy installed help/official reference and downstream prototype with sanitized live fixtures for tool payloads, permission decisions, trust, conversationId, /usage, quota text and headless denied_actions; record exact supported version and fail-closed unsupported contracts before implementing against assumptions.

- [x] TASK-AGR-002 Implement Python agy guard and merged hooks using canonical WSS locks and role context; verify malformed JSON, missing/stale locks, sentinel precedence, linked-worktree traversal, shell reads versus writes, URL tools and every floor pattern at both authority levels.

- [x] TASK-AGR-003 Add .agy.toml profiles, normalized agent alias, model forwarding and wrapper contract plus atomic narrowly scoped workspace trust; verify missing guard or unwritable trust refuses before agent start, restricted rejects always-proceed and unrelated global keys/mode remain intact.

- [x] TASK-AGR-004 Implement conversation-ID capture, exact resume and lifecycle-safe first-turn/kickoff behavior with auto-update disabled per session; verify Stop events append, session send/stop work, no duplicate kickoff and no claim caused by bare launch.

- [ ] TASK-AGR-005 Add Antigravity pane adapter and quota source wired into GSU, all applicable model-group buckets and resume reset resolution; verify working/idle/needs_input/limit fixtures, weekly versus short limits, unknown model mapping and exit-75 gate before trust/tmux. Requires integrated AGR-004 and GSU-006; ship quota payload/docs through installed update and append unsigned packed-consumer/live quota acceptance plus core lifecycle regression evidence. Full #54 completion requires this and AGR-008.

- [x] TASK-AGR-006 Ship workflow skills, profiles, hooks and guard through install/update/remove and package manifest with ordered named-hook merge; verify user hook entries survive repeated update and removal and every required helper is installed.

- [x] TASK-AGR-007 Write Antigravity guide, compatibility/authority limitations, AGENTS/templates/operating-model and doctor notes; verify --sandbox is rejected unless its worktree lifecycle is positively validated and separate specialist delegation stays one claimed Bead without specialist commit/close authority.

- [ ] TASK-AGR-008 Run scripts/test, packed consumer install/update/remove, live trusted and enforceable restricted tests, exact resume and one real Lead Bead lifecycle plus separate specialist session; commit unsigned acceptance with versions and #54 evidence, leaving any unsupported mode explicitly unadvertised. This is core runtime acceptance after AGR-007, independent of AGR-005/GSU; explicitly mark quota acceptance pending until AGR-005, and do not close #54 or sign human acceptance.

## Dependency contract

Explicit edges, not numeric task order, govern execution. Core order is AGR-001 -> AGR-002 -> AGR-003 -> AGR-004 -> AGR-006 -> AGR-007 -> AGR-008. AGR-002 also requires the already integrated WSS-005, SSP-003 and SPEC-2e64 foundations. AGR-005 requires AGR-004 and GSU-006. The SSP/SCM/CSL/GSU chain retains its existing edges; core agy is the next major execution priority without making SSP-005 depend on AGR-008. See design.md for exact Bead IDs and edge reconciliation. Core acceptance does not complete the full change while AGR-005 is pending.

## Execution contract

Every task is claimed by the Main Worker and implemented only in its own allocated worktree. Before allocating any dependent implementation worktree, verify every prerequisite execution commit is integrated into develop; Bead closure alone is insufficient. Relevant checks precede closure; run bd close, immediately scripts/nogg task-done, then commit the execution change and mapped tick together with the real Bead ID, and append SHA/evidence. Only the task-done mechanism may tick the mapped task during execution; agents do not hand-edit OpenSpec. Discoveries carry the discovery label and prose; no automatic GitHub issue closure or human sign-off.
