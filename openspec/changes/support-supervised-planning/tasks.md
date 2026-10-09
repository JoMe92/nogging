## 1. Implementation and validation

- [x] TASK-SSP-001 Add canonical planning role, planning-id/description validation and optional Bead with honest session metadata; verify Claude/Codex/Pi parsing, no placeholder Bead and rejection of execution role without a real Bead.

- [ ] TASK-SSP-002 Implement dedicated planning-worktree launch and role-specific prompt/kickoff with no claim or lock on bare launch; verify first kickoff acquires canonical lock itself and a second concurrent planner refuses without writing OpenSpec.

- [ ] TASK-SSP-003 Bind planning-lock lifecycle to session ownership and handle stop, failed launch, interrupted kickoff and cleanup safely; verify no other session lock is released, execution roles stay fenced during planning and crash recovery names the actual owner.

- [ ] TASK-SSP-004 Ship scoped supervised-launch permission guidance/effective settings plus doctor diagnostics for missing rules and unsupported auto-mode combinations; reproduce #52 on supported Claude, verify unrelated settings retained and direct agent/service fallbacks remain outside the grant.

- [ ] TASK-SSP-005 Reconcile AGENTS.md, templates, Claude/Codex/Pi planning commands, README and operating/security/session docs with role, commit-before-materialize, cleanup-before-plan-end and canonical locks; verify generated installed instructions agree.

- [ ] TASK-SSP-006 Run scripts/test and a supervised scratch planning lifecycle for supported installed agents through kickoff, lock, validated planning commit, materialize, local integration and safe cleanup; record #47/#52 evidence and leave human acceptance signatures blank.

## Execution contract

Every task is claimed by the Main Worker and implemented only in its own allocated worktree. Before starting a dependent change, verify the prerequisite branch is integrated into develop. Relevant checks precede closure; run bd close, immediately scripts/nogg task-done, then commit the execution change and mapped tick together with the real Bead ID, and append SHA/evidence. Only the task-done mechanism may tick the mapped task during execution; agents do not hand-edit OpenSpec. Discoveries carry the discovery label and prose; no automatic GitHub issue closure or human sign-off.
