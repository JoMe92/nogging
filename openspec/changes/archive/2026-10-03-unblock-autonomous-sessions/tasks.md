# Tasks — unblock autonomous sessions

- [x] TASK-UAS-001 In `.nogging/launch-prompts/autonomous.md`, beside the
      existing worktree-allocation bullet ("Before implementation, allocate a
      dedicated worktree from updated `develop` using `scripts/nogg worktree
      implement <bead> <branch>` and work only there"), add an explicit
      instruction to enter that worktree with a plain Bash `cd <path>` and to
      never use the `EnterWorktree` tool for it — name the reason briefly
      (the relocation-approval prompt it triggers cannot be suppressed by any
      permission rule, only by `bypassPermissions`, which `trusted` does not
      grant). Do not change `.nogging/launch-prompts/no-autonomous-claim.md`
      (see `design.md`, Decision 1, for why it does not need the same
      instruction). Closes GitHub issue #15.

- [x] TASK-UAS-002 In `.nogging/launch-profiles/trusted.json`, change
      `permissions.defaultMode` from `"acceptEdits"` to `"auto"`. Update the
      three places that describe the `trusted` profile's default mode as
      `acceptEdits`: `docs/operating-model.md` (the "Launch profiles"
      section, the `trusted (acceptEdits; allows ...)` parenthetical) and
      `docs/running-work-in-sessions.md` (the authority-levels table cell for
      `trusted` under Claude, and the "trusted starts in acceptEdits and
      allows..." bullet under "Running with broader authority"). Do not
      change `docs/running-work-in-sessions.md`'s separate description of
      `Shift+Tab`-cycling to `acceptEdits` during an attached session — that
      describes the generic manual mode-cycle, not `trusted.json`'s
      configured default, and is unaffected by this change. Closes GitHub
      issue #16.

- [x] TASK-UAS-003 In `scripts/session-launch`'s `codex)` branch, compute the
      shared checkout root (the directory the script itself lives under,
      resolved the same way regardless of the session's `--cwd`) and append
      `--add-dir "$repo_root"` to the Codex invocation, unconditionally,
      alongside the existing `--cd "$(pwd)"` — at every authority level, not
      only `trusted` (see `design.md`, Decision 3). Add a row/note to
      `docs/using-with-codex.md`'s level-detail table recording that both
      levels additionally grant the shared checkout's `.git`/`.beads` as
      writable via `--add-dir`, alongside the existing sandbox/approval/
      network/can-push columns. Closes GitHub issue #17.

- [x] TASK-UAS-004 Run `scripts/test` and confirm it passes with all three
      changes in place. Manually verify TASK-UAS-003 by launching
      `scripts/nogg session launch --role lead --bead <any open Bead>
      --agent codex --cwd <a worktree>` and confirming the resulting Codex
      invocation (visible in the session's recorded launch command / log
      banner) contains `--add-dir` pointed at the shared checkout root.
