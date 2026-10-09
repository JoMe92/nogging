## 1. Implementation and validation

- [ ] TASK-CSL-001 Run a traceable acceptance audit of existing #37–#40 behavior on installed payload: blocked/ready/orchestrator launches, default warning, explicit kickoff, trusted disclaimer handling and deny preservation; add only missing regressions and record exact versions without duplicating closed tasks.

- [ ] TASK-CSL-002 Correct sweep work scope and completion/integration evidence for lead and specialist sessions using mapped tasks and dependency cones; verify unrelated blocked siblings do not over-block, open/unknown PRs prevent completion and no-PR completion requires explicit integration evidence.

- [ ] TASK-CSL-003 Add explicit sweep --checks, cached PR/check fingerprints and session checks-ack with unknown/stale output and doctor cache reuse; verify a new failing CI run appears unchecked, an acknowledged fingerprint clears that flag and network errors never imply success.

- [ ] TASK-CSL-004 Correct placeholder-versus-input handling in nudge/send verification and docs; require explicit message on ambiguity, preserve non-running refusal and bound submit retry; verify real/fixture placeholder-only panes execute nothing and explicit messages submit reliably.

- [ ] TASK-CSL-005 Reconcile stale structured needs_input with live pane state and isolate session-observability tests from ambient NOGG_SESSION_NAME/NOGGING_ROOT; verify resolved rejection without Stop falls back, fresh real prompts stay needs_input and tests pass both inside/outside a supervised environment.

- [ ] TASK-CSL-006 Run scripts/test and live supported-runtime acceptance including two consecutive ready Beads in one authorized change, first-time launch/kickoff, blocked sibling and CI transition; commit unsigned evidence and an issue-by-issue #37–#42 closure checklist with any remaining blockers explicitly recorded.

## Execution contract

Every task is claimed by the Main Worker and implemented only in its own allocated worktree. Before starting a dependent change, verify the prerequisite branch is integrated into develop. Relevant checks precede closure; run bd close, immediately scripts/nogg task-done, then commit the execution change and mapped tick together with the real Bead ID, and append SHA/evidence. Only the task-done mechanism may tick the mapped task during execution; agents do not hand-edit OpenSpec. Discoveries carry the discovery label and prose; no automatic GitHub issue closure or human sign-off.
