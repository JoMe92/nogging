## 1. Implementation and validation

- [x] TASK-SCM-001 Extend Claude/Codex profile parsing with optional model and supported Codex model_reasoning_effort and add --model precedence; verify absent keys preserve behavior, wrong types/effort fail before session creation and Pi existing model selection remains valid.

- [ ] TASK-SCM-002 Forward selected model/effort through session-launch using separate argv elements and update the wrapper contract; verify stub Claude/Codex/Pi binaries receive exact flags with no interpolation or authority changes.

- [ ] TASK-SCM-003 Record requested model, source and runtime-default fallback and show them in session list/docs; verify per-launch overrides do not mutate profiles or global runtime settings.

- [ ] TASK-SCM-004 Run scripts/test, installed-payload model-selection scenarios and a live sandboxed Codex worktree lifecycle capability check; record #51 model-selection evidence, account for .git/.beads access honestly, and do not close the issue until both this and TASK-PSC-006 pass.

## Execution contract

Every task is claimed by the Main Worker and implemented only in its own allocated worktree. Before starting a dependent change, verify the prerequisite branch is integrated into develop. Relevant checks precede closure; run bd close, immediately scripts/nogg task-done, then commit the execution change and mapped tick together with the real Bead ID, and append SHA/evidence. Only the task-done mechanism may tick the mapped task during execution; agents do not hand-edit OpenSpec. Discoveries carry the discovery label and prose; no automatic GitHub issue closure or human sign-off.
