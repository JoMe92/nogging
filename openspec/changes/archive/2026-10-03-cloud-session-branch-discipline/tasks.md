# Tasks — cloud session branch discipline

- [x] TASK-CSB-001 Add a **Cloud sessions** rule to `templates/claude-block.md`
      and to `AGENTS.md`'s `### Claude Code` tool notes subsection (mirrored
      by `templates/agents-block.md` for consumer installs): the assigned
      `claude/*` branch is never a PR source; push the branch
      `nogg worktree implement`/`worktree plan` allocated and open the PR
      from that.

- [x] TASK-CSB-002 Add an optional `SessionStart` hook template, guarded by
      `if [ "$CLAUDE_CODE_REMOTE" != "true" ]; then exit 0; fi` (a no-op
      locally), that installs the pinned `bd`/Dolt versions from
      `docs/nogging/compatibility.md`, sets `core.hooksPath`, and runs
      `bd bootstrap`. Ship it under the installer payload as an opt-in
      template, not auto-wired into `.claude/settings.json` by default;
      document how a project that uses cloud sessions wires it in.

- [x] TASK-CSB-003 In `scripts/check-branch-name`, when the rejected `$ref`
      matches `^claude/`, print an additional line before `usage`: "cloud
      session branch: push the worktree branch from `nogg worktree
      implement` instead." Add the case to
      `scripts/hooks/branch-name.test.sh`.

- [x] TASK-CSB-004 Add a `doctor()` check: when `CLAUDE_CODE_REMOTE=true`,
      report as a NOTE whether `core.hooksPath` is set and whether `bd` is on
      `PATH`. Never a FAIL; never changes `doctor`'s exit code; prints
      nothing extra when not running in a cloud session.

- [x] TASK-CSB-005 Run `scripts/test`. Manually verify TASK-CSB-003 with
      `scripts/check-branch-name claude/some-session` and confirm the new
      hint line appears. Document the cloud-session rule and the
      `SessionStart` hook template in the installation docs
      (`docs/nogging/installation.md` or equivalent).
