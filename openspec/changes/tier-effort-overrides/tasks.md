## 1. Override mechanism (Part A)

- [x] TASK-TEO-001 [standard] Per design Decisions 1-3, 7: add tier_overrides validation and the override-aware model_selection_entry (effective effort, effort_source, table_effort) in scripts/nogg; `models check` counts the block, `models` shows `(project; table X)`, a malformed block refuses; add `"tier_overrides": {}` to templates/nogging-config.json. Check: new scripts/model-selection-overrides.test.sh written first and red; model-selection suite; scripts/test. Branch feat/.

- [ ] TASK-TEO-002 [standard] Per design Decisions 3-6: apply the override in resolve_launch_tier and _session_launch (explicit --effort > override > table > profile), record selection_tier_effort_source and reasoning_effort_source project, show `(project)` in session list, keep it on exact resume, refuse a malformed block before side effects. Check: new scripts/session-tier-overrides.test.sh first and red, with test-agents.sh stubs; scripts/test. Branch fix/. Depends on TEO-001.

- [ ] TASK-TEO-003 [standard] Per design Decision 8: add doctor NOTEs for a malformed block and a redundant override in model_selection_notes; model-drift NOTEs stay computed from the table alone. Check: extend scripts/model-selection-drift.test.sh first and red (override plus retired model prints the same drift NOTE, exit status unchanged, no block means no new NOTE); scripts/test. Branch refactor/. Depends on TEO-001.

## 2. Guidance (Part A)

- [ ] TASK-TEO-004 [routine] Per design Decisions 1, 4, 5, 7, 8: document tier_overrides, the new precedence rows, provenance, `models` display and the doctor NOTEs in docs/model-selection.md, docs/running-work-in-sessions.md and docs/architecture.md, plus a CHANGELOG Unreleased entry; the shipped table is untouched. Check: new assertions in scripts/runtime-guidance-docs.test.sh first and red; model-selection suite; scripts/test. Branch docs/.

- [ ] TASK-TEO-005 [routine] Per design Decision 9: state in .nogging/launch-prompts/orchestrator.md, .claude/commands/orchestrate.md and docs/operating-model.md that a Product Owner effort preference is recorded as a project tier_overrides entry via tracked work, never by bypassing --tier, with `--tier <t> --effort <e>` as the interim form. Check: prompt assertions in scripts/model-selection.test.sh first and red; cli and orchestrator suites; scripts/test. Branch chore/.

## 3. Packed verification (Part A)

- [ ] TASK-TEO-006 [standard] Per design Decisions 1, 5, 11: verify in a packed install that init scaffolds the empty tier_overrides block, update keeps a consumer's block byte for byte, and an installed-consumer tier launch fixture and `models check` honour it. Check: extend scripts/packed-model-selection.test.sh first and red (no network, no real agent); scripts/test with NOGG_* cleared. Branch test/. Depends on TEO-001, TEO-002, TEO-003.

## 4. Shipped defaults (Part B) - DECISION-NEEDED

- [ ] TASK-TEO-007 [standard] [DECISION-NEEDED] Part B: do NOT start until the Product Owner decides and records it on this Bead. Decision: change the shipped complex defaults for all projects (Claude opus xhigh to medium, Codex sol high to low), keep them, or change one agent. If decided: edit templates/model-selection.json, docs/model-selection.md and pinning tests (design Decision 10). Branch build/. No dependency edge; stays blocked.

## Dependency contract

Explicit blocking edges (`A <- B` means A depends on B):
TEO-002<-TEO-001; TEO-003<-TEO-001; TEO-006<-TEO-001,TEO-002,TEO-003.
TEO-001, TEO-004 and TEO-005 have no prerequisites and run in parallel. Markdown
order does not block work. TEO-007 has no edge in either direction: it is
materialized, then set `blocked` with the `decision-needed` label and a note
stating the open decision; nobody unblocks it except the Product Owner's
recorded decision. Before allocating a dependent worktree, verify every
prerequisite execution commit has reached develop, not merely that its Bead is
closed.

Branches are `<type>/tier-effort-overrides`: feat 001, fix 002, refactor 003,
docs 004, chore 005, test 006, build 007. The seven tasks use seven distinct
valid branch types, so no branch name is reused and any subset can run
concurrently.

## Execution contract

The Main Worker claims each task and implements it only in its own allocated
worktree on its lane branch, test first. Tests use stubs only (design Decision
11). Run each task's named checks, commit with a Conventional subject ending in
the real Bead token, then `bd close` and `scripts/nogg task-done` and append the
SHA and evidence to the Bead. Agents never hand-edit OpenSpec. Discoveries carry
the discovery label and prose. Nobody signs human acceptance.
