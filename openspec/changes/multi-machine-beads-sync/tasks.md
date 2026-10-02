# Tasks — opt-in multi-machine Beads sync

- [ ] TASK-MMB-001 Add `"multi_machine": false` as a new default key read
      from `.nogging/config.json` (matching the existing `scfg()`-style
      config accessors already used for other keys). Document it in the
      config reference.

- [ ] TASK-MMB-002 When `multi_machine` is `true`, add a *Multi-machine mode*
      section to the managed `AGENTS.md`/`CLAUDE.md` instruction block (and
      `templates/agents-block.md`/`templates/claude-block.md`): a `trusted`
      or orchestrator session runs `bd dolt pull` once at session start
      before reading Beads state, and `bd dolt push` before ending the
      session if it made any Bead write. State plainly that `restricted`
      sessions are unaffected and why (`design.md`, Decision 1).

- [ ] TASK-MMB-003 Add a `doctor()` check: when `multi_machine` is enabled
      and local Dolt has commits not present on the configured remote,
      print a NOTE naming the count. Never a FAIL; never changes `doctor`'s
      exit code.

- [ ] TASK-MMB-004 Add a short section to `docs/nogging/failure-recovery.md`
      covering a diverged-history scenario under multi-machine mode, pointing
      at `bd`'s own recovery guidance (the diverged-history message and its
      "bootstrap from one canonical clone" recovery path) rather than
      inventing a separate Nogging-specific procedure.

- [ ] TASK-MMB-005 Run `scripts/test`. Manually verify: with
      `multi_machine: true` set, a fresh clone on a second (throwaway)
      machine/checkout plus `bd dolt pull` shows a Bead created on the
      first; confirm `doctor` prints the ahead-of-remote NOTE after a local
      Bead write with no push yet, and confirm it prints nothing extra once
      pushed. With `multi_machine` unset (default), confirm `doctor` and the
      instruction block are unchanged from before this change.
