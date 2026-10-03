# Design — track change completion through delivery

## Decision 1 — do not add "Leads read proposal.md/design.md"

The source issue's expected-behavior list opens with "A Lead working a Bead
... reads the owning change (`proposal.md`, `design.md`, the relevant
`specs/**` deltas) before coding." This is declined, not implemented, because
it contradicts an existing, deliberate design choice stated in this project's
own `CLAUDE.md` / `AGENTS.md` "Lead Agent delegation" section: a Lead reads
*only* its one task line in `tasks.md` plus "the referenced spec excerpt, not
the whole `proposal.md` / `design.md`" — specifically to keep a Lead session's
context small, since `design.md` carries planning-time rationale a Lead does
not need to execute one already-agreed task.

That existing rule already includes reading "the referenced spec excerpt" —
the relevant `specs/<capability>/spec.md` delta — so the concrete thing the
issue's phrase gestures at (a Lead should know what capability behavior its
task is implementing) is already mandated. What is *not* mandated, and should
not be, is reading the WHY (`design.md`) or the full change narrative
(`proposal.md`). The observed symptom this change actually fixes — unticked
tasks, an empty archive — is fully explained by Decisions 2-4 below; nothing
about a Lead skipping `design.md` causes either symptom. Re-litigating this
rule is out of scope for a bug-fix-shaped change; if the Product Owner wants
it revisited, that is a separate, deliberate design conversation.

## Decision 2 — tick synchronously via a Lead-invoked command, not a hook

`bd hooks` has no close-time event (only git-lifecycle hooks), so there is no
native hook point to attach a tick to. The fix is a new, explicit primitive —
`scripts/nogg task-done <bead-id>` — that the Lead Agent's documented close
protocol calls as its own step, immediately after `bd close`. It:

1. Reads the Bead's `openspec:change:<change>` and `openspec:task:<TASK-ID>`
   labels (read-only `bd show`).
2. Refuses if the Bead is not actually closed (this command follows `bd
   close`, it does not replace it).
3. Ticks the matching `- [ ] TASK-ID` line in that change's `tasks.md`, using
   the exact same regex `sync()` already uses — extracted into one shared
   function both call, so there is one implementation of "what ticking
   means," not a second one that could drift from the first.
4. Does **not** also write the `execution-log.md` entry — that stays `sync`'s
   job (it already does it, keyed off the same closed-Bead state, and running
   it twice would risk a duplicate entry if both paths ever raced). A Lead
   session's `task-done` call only has to win the tasks.md tick before the
   session's own commit; the log entry can still arrive later from the timer
   without conflict, since `sync()`'s tick regex only matches an *unticked*
   box — once `task-done` has already ticked it, `sync()`'s later pass is a
   no-op for that line (naturally idempotent, confirmed by reading the regex:
   `^- \[ \] (TASK\b)` only matches the unticked form).

**No new commit trailer is needed.** `commit-msg` only validates the message
(Conventional subject plus a Bead-ID token or a `Nogging-Writer` trailer); it
does not restrict which files a commit touches. A Lead's own execution commit
already carries `[<bead-id>]` for its code change; bundling the `tasks.md`
tick into that same commit needs nothing extra. This resolves the open
question the `unblock-autonomous-sessions` planning session flagged in its
own notes about whether a writer trailer would be needed here — it would not.

**The `PreToolUse` guard does not block this either.** It intercepts only
Claude Code's own `Edit`/`Write`/`NotebookEdit` tool calls against
`openspec/` paths; a Bash-invoked `scripts/nogg task-done` writing the file
directly is invisible to it, exactly as `sync()` already is. No guard change
is needed.

## Decision 3 — doctor reports readiness; archiving itself is a planning action

`doctor` gains a NOTE (never a FAIL — matches its existing advisory pattern
for `sync` skips and stale rules) when a live change's every mapped Bead is
closed, using the **closed-inclusive** Beads enumeration `sync()` and
`materialize()` already use (the same fix `reliable-beads-sync` shipped for
the "bd list omits closed" gap) — not the default `bd list --json`, which
would under-report. `doctor` does not archive anything itself: archiving
writes `openspec/`, which is read-only outside a planning session, so the
action belongs to `/plan`, not to a mechanical, always-runnable diagnostic.

## Decision 4 — the archive step in `/plan` is conditional, not mandatory busywork

Adding a mandatory "archive something" step to every planning session would
either no-op constantly (nothing to archive) or force an unrelated planning
session to also handle archival bookkeeping. Instead, `/plan`'s sequence gains
a conditional step, placed right after discovery review and before the design
dialogue: if `scripts/nogg doctor` reports a change ready to archive, archive
it (`openspec archive <change>`, review the merged `specs/`, `validate`,
commit as the `planning` writer) before authoring any new change content —
so a fresh change's own spec deltas are never written against a not-yet-
merged prior change's stale "current" specs.

## Non-goals

- No change to how `materialize` or `validate` already treat archived
  changes (`run-hygiene`'s "invariant audit tolerates archived changes" is
  unaffected).
- No automatic archiving — a human- or Orchestrator-directed planning session
  still performs the actual `openspec archive` call; this change only makes
  readiness visible and adds the step where it belongs.
