## 1. Launch flag

- [x] TASK-CEF-001 [standard] Per design Decisions 1-4, 6: accept `--effort` for Codex in scripts/nogg (validated before side effects, forwarded as --reasoning-effort, over tier and profile, source launch), keep selection_tier with --tier --model --effort, refuse pi/antigravity with the Claude-and-Codex wording, decide the resume case. Stub tests in session-effort and session-tier suites. Check: those, session-model-forwarding, model-selection; scripts/test. Branch feat/.

## 2. Docs

- [x] TASK-CEF-002 [routine] Per design Decisions 2, 3, 5: update docs/model-selection.md (Codex effort precedence, Codex cost policy with Luna default, Sol only with effort low for extremely hard tasks, both command spellings), running-work-in-sessions.md, using-with-codex.md and architecture.md. Check: model-selection and runtime-guidance-docs suites with a new policy/spelling assertion; scripts/test. Branch docs/.

## 3. Orchestrator guidance

- [x] TASK-CEF-003 [routine] Per design Decision 5: add the Codex policy and both command spellings to .nogging/launch-prompts/orchestrator.md, .claude/commands/orchestrate.md and docs/operating-model.md Orchestration (explicit --model or --effort only on PO instruction, keep the honest tier). Check: model-selection prompt assertions extended; cli and orchestrator suites; scripts/test. Branch chore/.

## Dependency contract

No Beads dependency edges: TASK-CEF-001, 002 and 003 are independent and can start at once on three distinct branch prefixes. Branches are `<type>/codex-effort-flag`: feat/ 001, docs/ 002, chore/ 003. Each task's full contract is its design Decision plus the requirements of the capability specs in this change.

## Execution contract

The Main Worker claims each task and implements it only in its own allocated worktree on its lane branch. Follow design Decision 6 for every test: no network, no real codex or tmux, stubs only. Run each task's named checks, commit with a Conventional subject ending in the real Bead token, then run bd close and scripts/nogg task-done and append the SHA and evidence to the Bead. Agents never hand-edit OpenSpec. Discoveries carry the discovery label and prose. Nobody signs human acceptance.
