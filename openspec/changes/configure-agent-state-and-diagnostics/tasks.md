## 1. Implementation and validation

- [ ] TASK-ASD-001 Add validated agent_state_roots config (template: antigravity ~/.gemini/antigravity-cli), agent-state:<agent> Bead label and --agent-state option, one writable-root resolver shared with doctor, recorded/listed grants and refusal of a set NOGG_CODEX_EXTRA_WRITABLE_ROOTS; verify labelled/unlabelled launches and refusals before tmux/record; update Codex/Antigravity/security docs.

- [ ] TASK-ASD-002 Add the NOTE-only Codex sandbox diagnosis to doctor using the shared resolver: offline create/remove probes in the shared and worktree Git directories by default, and doctor --sandbox SSH fetch and bounded scripts/test probes; plus agent_state_roots WARN/NOTE checks; verify writable, read-only, unsupported/absent codex and non-SSH-remote cases leave no residue and never change exit status.

- [x] TASK-ASD-003 Ship templates/claude/orchestrator-permissions.example.json (sibling worktree path pattern allows, scripts/nogg allows, deny list superset of FLOOR_DENY plus history-destroying Git) and document it with the auto-mode classifier and user-only autoMode limits after verifying them against installed Claude Code and official docs; add a drift test and verify init/update never apply it.

- [ ] TASK-ASD-004 Reconcile the owner-requested autonomous Claude configuration already delivered by SPEC-u57h in commit 1ae9dab (pinned trusted profile/autonomous prompt labelled by file name, documented Cloud settings); verify it is on develop and the configured-launch session test passes, then close through task-done without re-implementation.

- [ ] TASK-ASD-005 Run scripts/test, a live labelled Codex session that runs agy with its state root granted while an unlabelled session stays unwidened, and doctor plus doctor --sandbox on this host; record versions and evidence in the Bead notes without signing acceptance.

## Execution contract

Every task is claimed by the Main Worker and implemented only in its own allocated worktree. Before starting a dependent change, verify the prerequisite branch is integrated into develop. Relevant checks precede closure; run bd close, immediately scripts/nogg task-done, then commit the execution change and mapped tick together with the real Bead ID, and append SHA/evidence. Only the task-done mechanism may tick the mapped task during execution; agents do not hand-edit OpenSpec. Discoveries carry the discovery label and prose; no automatic GitHub issue closure or human sign-off.
