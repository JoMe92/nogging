# Track change completion through delivery

## Source

[GitHub issue #24](https://github.com/JoMe92/nogging/issues/24) — "OpenSpec
progress is not tracked during Bead delivery: tasks stay unticked, completed
changes never archived, Leads don't read the spec." Observed on a real
delivery run: ~400 Beads closed, yet `openspec list` still reported `0/N
tasks` for essentially every change, and `openspec/changes/archive/` stayed
empty for ~60 delivered changes.

## Research performed

Read `scripts/nogg`'s `sync()` and `doctor()` directly, and the Beads CLI's
own `hooks`/`close` help output, rather than assuming the issue's diagnosis.
Three findings materially change the fix from what the issue proposes:

1. **Ticking already exists, asynchronously.** `sync()` already ticks a
   `tasks.md` checkbox for every closed, mapped Bead it finds (regex-replaces
   `- [ ] TASK-X` to `- [x] TASK-X`) and appends the matching execution-log
   entry. The observed `0/N tasks` is consistent with that mechanism simply
   not having run yet (or not being installed) on the project the issue was
   filed from, not with Nogging having no mechanism at all. The real gap is
   that this only happens on the sync timer's schedule (and `sync` itself
   refuses to run in several safe-but-common states — a held planning lock, a
   protected branch — see the `sync-safety` capability), not at the moment a
   Lead session closes its own Bead.
2. **No git hook fires on `bd close`.** `bd hooks` only wires `pre-commit`,
   `post-merge`, `pre-push`, `post-checkout`, and `prepare-commit-msg` — there
   is no close-time hook to attach a tick to. A synchronous fix has to be an
   explicit step the Lead Agent's own close protocol calls, not something
   Beads triggers on its own.
3. **The OpenSpec write boundary does not block this.** The `PreToolUse`
   guard (`scripts/hooks/pre-tool-use-openspec-guard`) only intercepts
   Claude Code's own `Edit`/`Write`/`NotebookEdit` tool calls against
   `openspec/` paths — it has no visibility into a Bash-invoked script
   writing the same file directly, which is exactly how `sync()` already
   gets away with writing `tasks.md` and `execution-log.md` outside a
   planning session. The `commit-msg` hook separately checks only the commit
   *message* (Conventional subject + Bead-ID token or a `Nogging-Writer`
   trailer) — it does not restrict which paths a commit may touch. So a new
   Bash-invoked helper that ticks `tasks.md`, bundled into the Lead's own
   `[<bead-id>]`-tokened execution commit, needs **no new trailer and no
   guard change** — it is already legal under the existing mechanism, exactly
   parallel to how `sync()`'s commits are legal under `Nogging-Writer: sync`.

See `design.md` for why one part of the issue's own proposal — "Leads read
`proposal.md`/`design.md` before implementing" — is declined rather than
implemented.

## Why

Beads and OpenSpec are supposed to be two views of the same state. When
`tasks.md` and the archive drift from what Beads actually shows, the
Product Owner and reviewers lose the one artifact (`openspec list` / specs)
meant to answer "what's actually done," and a later planning session plans
against stale "current" specs because the archive-and-merge step never ran.

## What Changes

- A new `scripts/nogg task-done <bead-id>` command ticks the matching
  `tasks.md` checkbox for an already-closed, mapped Bead — the same tick
  logic `sync()` already uses, extracted into one shared helper so there is
  exactly one implementation of "how a task gets ticked," not two. The Lead
  Agent's close protocol (`AGENTS.md`, `templates/claude-block.md`,
  `templates/agents-block.md`) gains this as an explicit step, bundled into
  the same commit as the Bead's own `[<bead-id>]`-tokened execution commit.
- `scripts/nogg doctor` gains a NOTE-level check: a live (non-archived)
  change whose every mapped Bead is closed, per the same closed-inclusive
  Beads enumeration `sync()`/`materialize()` already use, is reported as
  ready to archive.
- `/plan`'s documented sequence (`.claude/commands/plan.md`,
  `.codex/prompts/plan.md`, `docs/operating-model.md`'s step table) gains an
  explicit step: archive any change `doctor` reports as ready before
  authoring new change content.
- The Orchestration Agent's prompt and `docs/operating-model.md`'s
  *Orchestration* section are told to treat a `doctor` archive-readiness NOTE
  as a signal to direct a planning session's archive step.

## Out of scope

- **Not adding** "Leads read `proposal.md`/`design.md` before implementing" —
  see `design.md`, Decision 1. This declines one clause of the source issue
  with a stated reason, rather than silently dropping it.
- No change to `sync()`'s own refusal conditions (held lock, protected
  branch, mid-merge) — `sync-safety`'s existing requirements are unaffected;
  this change adds a second, synchronous path to the same end state, it does
  not alter the timer's behavior.
