## 1. Implementation and validation

- [ ] TASK-GSU-001 Verify installed Codex rollout/Claude statusline usage schema and implement read-only normalized adapters plus nogg usage text/JSON; test both windows, missing/stale/malformed records, timezone/reset rollover and absence of credential/transcript output.

- [ ] TASK-GSU-002 Implement validated usage_gate config and cap/estimate/size-label calculation with explicit unknown policy and --ignore-usage-gate; verify supported defaults, bad configuration rejection and denied admission exit 75 before any worktree/trust/tmux/record side effect.

- [ ] TASK-GSU-003 Add same-host atomic per-account/bucket admission reservations with lifecycle cleanup and stale-owner recovery; verify two simultaneous launches cannot both spend the final slot, failed launch releases reservation and unrelated accounts/groups are independent.

- [ ] TASK-GSU-004 Record bounded per-agent/model usage history and conservative learned medians only for attributable complete non-reset intervals; verify overlap/reset/outlier samples are rejected, insufficient data uses fallback and no credential/account identifier is exposed.

- [ ] TASK-GSU-005 Provide explicit statusline-cache installation/composition, doctor freshness hints and orchestrator retry guidance; verify existing statusline/user settings preserved, unknown warns by default and scheduling uses all limiting reset windows without model switching.

- [ ] TASK-GSU-006 Run scripts/test plus concurrent stub admission and installed-payload tests; perform read-only live quota observation and an authorized single scratch launch, recording #53 evidence and documenting same-host scope and estimation limits.

## Execution contract

Every task is claimed by the Main Worker and implemented only in its own allocated worktree. Before starting a dependent change, verify the prerequisite branch is integrated into develop. Relevant checks precede closure; run bd close, immediately scripts/nogg task-done, then commit the execution change and mapped tick together with the real Bead ID, and append SHA/evidence. Only the task-done mechanism may tick the mapped task during execution; agents do not hand-edit OpenSpec. Discoveries carry the discovery label and prose; no automatic GitHub issue closure or human sign-off.
