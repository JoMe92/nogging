## 1. Implementation and validation

- [x] TASK-PSC-001 Add both wrappers to manifest verbatim/executable lists and assert npm payload coverage; verify fresh init and update from a fixture missing or containing old wrappers produce executable current copies while preserving OpenSpec, Beads and unrelated target content.

- [x] TASK-PSC-002 Add a side-effect-free launch-wrapper contract handshake and preflight all emitted flags including session-id, resume, remote-control and per-agent options; verify mismatched/missing/non-executable wrappers refuse before any tmux call or session record.

- [x] TASK-PSC-003 Capture startup stderr before the child can exit and report the real redacted cause with a failed lifecycle record; verify an immediate unknown-flag/exec failure produces a readable log rather than only cannot-find-pane.

- [ ] TASK-PSC-004 Add doctor payload/contract diagnostics and make shipped self-tests honor optional configuration defaults and consumer-local fixtures; verify a minimal legacy config without claim_stale_seconds and installed documentation links in a scratch consumer.

- [ ] TASK-PSC-005 Document managed wrapper replacement, preflight errors and supported update recovery; verify init/update/update/remove preserves unrelated hooks, profiles outside owned names, OpenSpec and Beads, including paths containing spaces.

- [ ] TASK-PSC-006 Run scripts/test plus packed-package fresh-install/old-install-update launch tests with stub agents; record version, payload inventory and evidence for #43 and the installer portion of #51 without claiming model selection is complete.

## Execution contract

Every task is claimed by the Main Worker and implemented only in its own allocated worktree. Before starting a dependent change, verify the prerequisite branch is integrated into develop. Relevant checks precede closure; run bd close, immediately scripts/nogg task-done, then commit the execution change and mapped tick together with the real Bead ID, and append SHA/evidence. Only the task-done mechanism may tick the mapped task during execution; agents do not hand-edit OpenSpec. Discoveries carry the discovery label and prose; no automatic GitHub issue closure or human sign-off.
