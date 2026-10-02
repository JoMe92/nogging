# Tasks — track change completion through delivery

- [x] TASK-TCC-001 Extract the `tasks.md`-ticking logic `sync()` already uses
      (the `- [ ] TASK-X` → `- [x] TASK-X` regex replace, keyed off
      `task_map()`/`mapping(issue)`) into one shared helper function. Add
      `scripts/nogg task-done <bead-id>`: resolves the Bead's
      `openspec:change:`/`openspec:task:` labels via `bd show`, refuses if the
      Bead is not closed, and ticks the matching line using the shared
      helper. Does not write `execution-log.md` (stays `sync()`'s job; see
      `design.md`, Decision 2, for why this is safe and idempotent either
      order).

- [x] TASK-TCC-002 Update the Lead Agent close protocol everywhere it is
      documented — `AGENTS.md`, `templates/claude-block.md`,
      `templates/agents-block.md` — to call `scripts/nogg task-done <id>`
      immediately after `bd close <id>`, bundled into the same commit as the
      Bead's own `[<bead-id>]`-tokened execution commit. Do not add any new
      commit trailer (see `design.md`, Decision 2 — the existing Bead-ID
      token already makes this legal).

- [x] TASK-TCC-003 Add a `doctor()` check: for each live (non-archived)
      change under `openspec/changes/`, using the closed-inclusive Beads
      enumeration (`beads()`/`task_map()` as `sync()`/`materialize()` already
      call it, not the default closed-excluding `bd list`), if every Bead
      mapped to that change is closed, print a NOTE naming the change as
      ready to archive. Never a FAIL; never changes `doctor`'s exit code.

- [ ] TASK-TCC-004 Add a conditional archive step to `/plan`'s sequence,
      placed after discovery review and before the design dialogue, in every
      place the sequence is documented: `.claude/commands/plan.md`,
      `.codex/prompts/plan.md`, and the step table in
      `docs/operating-model.md`. Wording: if `scripts/nogg doctor` reports a
      change ready to archive, archive it (`openspec archive <change>`,
      review the merged `specs/`, `validate`, commit as the `planning`
      writer) before authoring any new change content.

- [ ] TASK-TCC-005 Update `.nogging/launch-prompts/orchestrator.md` and
      `docs/operating-model.md`'s *Orchestration* section: when `doctor`
      reports a change ready to archive, the Orchestration Agent directs a
      planning session to run the archive step (TASK-TCC-004) — either by
      starting one, or by naming it to an already-running one.

- [ ] TASK-TCC-006 Run `scripts/test`. Manually verify TASK-TCC-001/002 by
      closing a throwaway mapped Bead, running `task-done`, and confirming
      the exact `tasks.md` line ticks and `sync()`'s later pass is a no-op
      for that line. Manually verify TASK-TCC-003 by closing every Bead of a
      throwaway change and confirming `doctor` prints the NOTE.
