# Tasks — dependency-aware session launch

- [ ] TASK-DAL-001 Before writing any code: create a scratch dependency
      between two throwaway Beads (`bd create`, then `bd dep add <blocked>
      <blocker>`), run `bd dep list <blocked> --json`, and record the real
      field names (in particular, how the blocker's own status is
      represented) in this task's close-out note. Delete the two scratch
      Beads afterward. Then, in `scripts/nogg` (Python), add a helper that
      calls `bd dep list <bead_id> --json` (`--direction down`, the default)
      and returns the list of blocking Bead IDs whose own status is not
      `closed` (empty list when none). In `session_launch()`, for `role ==
      "lead"` or `role.startswith("specialist:")` only, call this helper
      immediately after the existing `bead_exists()` check and before any
      tmux session or metadata record is created; raise `RuntimeError`
      naming every blocking Bead ID when the list is non-empty, mirroring
      the existing `bead_exists` failure shape exactly (no tmux session, no
      record written). `--role orchestrator` is unaffected. Closes GitHub
      issue #37's primary fix.

- [ ] TASK-DAL-002 Add `scripts/hooks/pre-tool-use-lead-launch-guard`,
      mirroring `scripts/hooks/pre-tool-use-openspec-guard`'s structure: read
      stdin JSON, extract `.tool_input.command` (the `Bash` tool's command
      string, not `.tool_input.file_path`), and only act when that string
      contains `scripts/nogg session launch` together with `--role lead` or
      a `--role specialist:` value, and a `--bead <id>` argument (simple
      substring/argument scanning, not a full shell parse — matching the
      existing guard's own level of rigor). When matched, run TASK-DAL-001's
      helper directly (shell out to `bd dep list`, not to `scripts/nogg`
      itself) and `exit 2` with a clear stderr message naming the blocking
      Bead ID(s) if any are unmet; `exit 0` otherwise. Wire it into this
      repository's own `.claude/settings.json` as a new `PreToolUse` entry
      with `"matcher": "Bash"` (a sibling entry to the existing `Edit|Write`
      one, not a replacement). Add `bin/lib/merge.js` support for it: a
      second `GUARD_MARKER`/`GUARD_ENTRY`-style idempotent merge targeting
      the `Bash` matcher, following the existing `mergeClaudeSettings`
      pattern exactly (own marker, own entry, inserted once, every other
      hook left untouched). Add `scripts/hooks/pre-tool-use-lead-launch-guard`
      to both verbatim-file lists in `bin/lib/manifest.js` (the two existing
      arrays that already name `pre-tool-use-openspec-guard`, at lines ~26
      and ~91) and to `package.json`'s `files` array (which already lists
      `pre-tool-use-openspec-guard`), so the new hook installs the same way
      downstream. Closes GitHub issue #37's Claude-only fast backstop.

- [ ] TASK-DAL-003 In `scripts/nogg doctor`, for every session `session
      list` would show as `running` with role `lead` or `specialist:*`,
      call TASK-DAL-001's helper against its `bead_id` and print one `NOTE`
      per session whose Bead now has an unmet dependency, naming the session
      and the blocking Bead ID(s). This is read-only — `doctor` never stops
      or otherwise changes a flagged session. Closes GitHub issue #37's
      retroactive-blocking detection.

- [ ] TASK-DAL-004 Add the spec delta (see `specs/claude-sessions/spec.md`
      in this change) and run `scripts/nogg validate`. Add/extend
      `scripts/nogg.test.sh` cases: a Lead/specialist launch refused for a
      Bead with a recorded, unmet dependency (naming the blocking Bead in
      the error, and asserting no tmux session or record was created); the
      same launch allowed once the dependency is closed; a Bead with zero
      dependencies and `--role orchestrator` both unaffected. Add a
      `scripts/hooks/pre-tool-use-lead-launch-guard.test.sh` (mirroring
      `scripts/hooks/branch-name.test.sh`'s style) covering: the hook exits 2
      with a clear message for a matching, blocked launch command; exits 0
      for a matching but unblocked one; exits 0 for a non-matching `Bash`
      command (e.g. `ls`, or a `session launch` for `--role orchestrator`).
      Add a case to `bin/`'s own install/merge test coverage confirming
      `mergeClaudeSettings`-equivalent logic inserts the new `Bash` matcher
      entry exactly once and leaves the existing `Edit|Write` entry
      untouched on a second `update` run. Run `scripts/test` and confirm it
      passes.
