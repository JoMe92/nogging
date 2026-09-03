# Make an interrupted planning or development run safe to resume

## Why

A planning run or a development run can stop mid-way — the token budget runs
out, the process crashes, the SSH session drops, or the operator switches tools
(Claude Code ↔ Codex). `docs/source/crash-resilience-handoff.md` analysed what
survives (git, Beads, `openspec/`, `.specforge/state/`) and what does not (the
agent's in-flight reasoning), and found several ways a restart goes wrong:

- **A committed-but-not-closed Bead is invisible.** A commit lands with its
  `[SPEC-xxx]` token, the process dies before `bd close`, and nothing notices:
  `sync` only mirrors closed Beads, `validate` has no check for it. Whoever
  resumes may re-implement the same task and produce a duplicate commit.
- **`materialize` runs before the planning commit.** A crash between the two
  leaves Beads in the DB with no committed spec; a botched `tasks.md` write then
  orphans them and `validate`/`sync` fail permanently.
- **There is no resumption protocol.** Each fresh or switched-tool session
  starts from `bd ready` with no "check what was in flight first" step, and no
  single command that produces the picture.

The sync-timer branch race (W5) from the same handoff is already fixed by
`sync-timer-branch-safety`; this change covers the rest.

## What Changes

- **`scripts/specforge recover`** — a read-only diagnostic that reports, and
  exits non-zero when anything needs attention: lock freshness; committed-but-
  open Beads (`LIMBO`); `in_progress` Beads classified `resumable`/`stale`/
  `active`; a materialized-but-uncommitted change; orphan Beads; crashed session
  records; the working-tree / mid-operation state; last-sync age.
- **`validate()` gains a `warnings` return** and a committed-but-open-Bead
  (`LIMBO`) warning — surfaced by `doctor`, `recover`, and the sync audit, but
  never a hard `AuditError` (the timer keeps mirroring the Beads that *are*
  closed).
- **The canonical planning flow reorders to commit the spec before
  `materialize`.** Updated in `docs/operating-model.md`, `AGENTS.md`,
  `templates/*-block.md`, the `.claude/commands/plan.md` / `.codex/prompts/plan.md`
  sequence, and any guidance `scripts/specforge` prints. `materialize()` writes a
  `.specforge/state/materialize-<change>.json` journal so a resume knows where it
  stopped.
- **A "Resuming a run" protocol in `AGENTS.md`** (run `recover` before
  `bd ready`) plus a per-item **playbook** in `docs/failure-recovery.md`.
- **An intent-breadcrumb rule in `AGENTS.md`** — before an expensive or
  hard-to-reverse step, and before ending a turn with a Bead still
  `in_progress`, append a one-line "next step" to the Bead note.
- **`session reap`** — move every active-state session record whose tmux is gone
  to `failed`, so `session cleanup` can retire it; `docs/failure-recovery.md`
  leads the crashed-session steps with it.
- **Stale-claim labelling** — `recover` marks a claim older than a config
  `claim_stale_seconds` as `stale`.
- **A Dolt durability checkpoint** (after verifying the current cadence) — a
  `bd dolt commit` at the end of `sync()` and `materialize()` if bead state can
  otherwise sit uncommitted in the working set.

## Capabilities

### New Capabilities

- `run-recovery`: an interrupted planning or development run can be diagnosed
  with one command and resumed safely — no lost work, no duplicated work — and
  the planning flow and instructions are ordered so a crash leaves a consistent
  state.

### Modified Capabilities

<!-- none -->

## Impact

- New code: `scripts/specforge` (`recover`, `validate` warnings, `materialize`
  journal + reorder guidance, `session reap`, `doctor` integration, config
  keys), `.specforge/config.json` (`claim_stale_seconds`).
- Modified: `AGENTS.md`, `CLAUDE.md`, `templates/claude-block.md`,
  `templates/agents-block.md`, `.claude/commands/plan.md`,
  `.codex/prompts/plan.md`, `docs/operating-model.md`, `docs/failure-recovery.md`,
  `scripts/specforge.test.sh`, `scripts/session.test.sh`.
- Behavioural change: the planning flow order changes (commit then materialize);
  a fresh/resumed session is expected to run `recover` first.
- Depends on nothing hard; complements `sync-timer-branch-safety` (W5) and
  `tool-agnostic-write-boundary` (W6, already merged).
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
