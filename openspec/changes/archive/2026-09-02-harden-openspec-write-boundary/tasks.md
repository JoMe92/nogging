# Tasks

- [x] TASK-BOUNDARY-001 Rewrite the discovery convention in `AGENTS.md` and `docs/architecture.md` to use the native `discovery` Beads label plus a required human-readable note, removing the fenced `specforge-discovery` JSON block.
- [x] TASK-BOUNDARY-002 Update the discovery-reading path in `scripts/specforge` to locate pending discoveries by the `discovery` label only, without parsing note contents.
- [x] TASK-BOUNDARY-003 Extend `scripts/hooks/commit-msg` to require a real Beads issue ID token (e.g. `[SPEC-abc]`) in execution commit subjects, exempting commits whose `SPECFORGE_WRITER` is `planning` or `sync`, with a rejection message that names the rule and the exemption.
- [x] TASK-BOUNDARY-004 Add a regression check (script test or CI invariant) covering accept-with-ID, reject-without-ID, and both `SPECFORGE_WRITER` exemptions.
- [x] TASK-BOUNDARY-005 Add a `PreToolUse` hook to `.claude/settings.json` matching `Edit|Write` that blocks writes under `openspec/` when `.specforge/locks/planning.lock` is absent and exits non-zero, preserving the existing `SessionStart` hook.
- [x] TASK-BOUNDARY-006 Verify the `PreToolUse` file-path input mechanism against the installed Claude Code version and confirm the real Beads issue ID prefix from `.beads/`.
- [x] TASK-BOUNDARY-007 Document the three enforcement layers (PreToolUse, pre-commit, commit-msg) and their interaction in `docs/architecture.md`.
