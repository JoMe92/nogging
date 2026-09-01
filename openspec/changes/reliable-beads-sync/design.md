# Design

## Context

`scripts/specforge` is the deterministic bridge described in the concept
conversation: no LLM, no product decision, just data reconciliation between
Beads (what is happening) and OpenSpec (what was agreed). Its `sync()` pass
already takes an exclusive lock, runs the invariant audit, checks task
checkboxes, and appends `execution-log.md` entries keyed by a stable
`<!-- specforge:<id>:<timestamp> -->` marker so re-runs are idempotent.

Three of its Beads reads go through `bd list` without a status filter, which
Beads scopes to non-closed issues by default:

- `beads()` — feeds the audit and the sync pass.
- `pending_discoveries()` — feeds `./scripts/specforge discoveries`.

Closed Bead SPEC-1cu carries the `discovery` label and a review note describing
the first of these gaps. It is itself the worked example: a closed, mapped,
discovery-labelled Bead that the current code cannot see.

Failure persistence is a single overwrite of `.specforge/state/last-error.json`.

## Goals / Non-goals

- Goal: a closed mapped Bead is mirrored to its task checkbox and the change
  execution log, exactly once, no matter how many times sync runs.
- Goal: an execution-log entry carries enough closure evidence (Bead ID,
  closure time, note, commit references when present) to stand in for the
  implementation note that classic OpenSpec would put in the spec.
- Goal: discovery review never silently omits a discovery because it was closed
  before a planning session looked at it.
- Goal: a failed sync is classifiable (transient vs permanent) and carries
  bounded retry metadata.
- Non-goal: materializing Beads for this change.
- Non-goal: editing implementation files in this planning session.
- Non-goal: automating discovery classification, changing the change lifecycle
  (`open`, `done`, `archived`), or having sync close Beads, archive, or push.
- Non-goal: size-based rotation of the failure log (noted in the conversation
  but not required to close these gaps; can follow later).

## Decisions

### Enumerate closed mapped Beads explicitly

`beads()` (and any discovery read) must union the default non-closed set with an
explicit `bd list --status closed --json` query, or use a single
comma-separated `--status open,in_progress,blocked,deferred,closed` request.
The sync pass keeps its existing `status == "closed"` filter for the mirror
step; the fix is purely that closed Beads now reach that filter.

The same closed-status omission bites `materialize()` independently: it builds
its "already mapped" set from `beads()` and skips any task already in it, so once
a task's Bead is closed the guard no longer sees it and a re-run of
`./scripts/specforge materialize <change>` creates a duplicate Bead for that
task (discovery SPEC-dvu — seven duplicates observed during `specforge-installer`).
Feeding `materialize()`'s existing-set check from the same closed-inclusive read
fixes both call sites at once.

Idempotency is unchanged in mechanism: the mirror step is gated by the
`<!-- specforge:<id>:<updated_at|closed_at> -->` event key already present in
`execution-log.md`, and the checkbox rewrite only flips `- [ ]` to `- [x]`.
Re-running sync after a closed Bead is already mirrored produces no diff. A
closed fixture in `scripts/specforge.test.sh` locks this in: run sync twice
against a stub `bd` that returns a closed mapped Bead, assert exactly one log
entry and one checkbox flip.

### Execution-log entry contents

Each mirrored entry renders, in a stable format:

- the Bead ID and the mapped task ID (already present);
- the Bead's closure timestamp from `closed_at` (falls back to `updated_at`
  only if `closed_at` is absent);
- the Bead's human-readable `notes`, preserved verbatim, indented as a block so
  the log stays readable;
- implementation commit references when present.

**Determining commit references** without a native Beads field: scan
`git log --format=%H %s` for subjects containing the Bead ID token
(`[<PREFIX>-<id>]`, the same token the `commit-msg` hook enforces), and include
any 7–40 hex SHA already written into the Bead note by the execution agent
(`AGENTS.md` rule 3). De-duplicate. When none are found, the entry is still
written and states that no commit reference was found — absence is recorded, not
skipped.

The event key stays `closed_at`/`updated_at`-based, so if an agent later amends
the note or a follow-up commit lands, the timestamp moves and a new entry is
appended rather than mutating history — consistent with "roll back with a Git
revert" in `docs/failure-recovery.md`.

### Closed-discovery review with an acknowledgement ledger

`discoveries` enumerates every Bead carrying the `discovery` label regardless of
status. Blocking discoveries still sort first; closed discoveries sort after
open ones and are labelled as closed-but-unreviewed.

To stop a reviewed discovery from resurfacing forever, a planning session
acknowledges it. The acknowledgement ledger is a JSON file under
`.specforge/state/` (for example `acknowledged-discoveries.json`) mapping Bead
ID to an acknowledgement timestamp. `discoveries` hides any Bead already in the
ledger. Writing the ledger is an explicit planning-session action (a new
`discoveries --ack <id>...` subcommand or equivalent), never automatic — the
mechanical layer records the acknowledgement, it does not decide it.

This keeps the rule mechanical: "show every discovery-labelled Bead not yet
acknowledged", open or closed. SPEC-1cu would appear until a planning session
acknowledges it.

### Structured, classified failure records

Replace the `last-error.json` overwrite with a structured active-failure record
under `.specforge/state/` containing:

- `classification`: `transient` or `permanent`;
- `error`: the message;
- `attempts`: count of consecutive failed syncs for this failure;
- `max_attempts`: the bounded cap (config value, e.g. `sync_max_attempts`);
- `first_seen`, `last_seen`: timestamps;
- `next_retry_after`: `last_seen` plus exponential backoff, capped.

**Classification rule** (mechanical, from the exception type/source):

- *Transient* — lock contention (sync lock held, not yet stale), `git` or `bd`
  invocation failures that look like I/O or transient process errors, JSON
  decode of a partial `bd` response. Eligible for retry until `attempts`
  reaches `max_attempts`.
- *Permanent* — the invariant audit failed (`validation failed` / `audit
  failed`), a mapping conflict, a missing task, a malformed `tasks.md`. Not
  retried automatically; the operator must resolve the underlying disagreement.

On any failure, append a line to a JSONL failure log
(`.specforge/state/sync-failures.jsonl` or similar) with the same fields plus
the event time. On the next successful sync, delete the active-failure record
(the JSONL history is retained). `./scripts/specforge doctor` reads the new
record shape and reports classification, attempts, and `next_retry_after`.

The daemon/cron caller is expected to consult `next_retry_after` and
`classification` before re-invoking sync; `sync` itself stays a single-shot
command and does not sleep or loop.

## Risks / open questions

- Beads status vocabulary: the design assumes `open, in_progress, blocked,
  deferred, closed` per `bd list --status` help. Execution should confirm no
  additional terminal status exists that also needs mirroring.
- Large Bead notes could make `execution-log.md` noisy. The design keeps the
  full note verbatim (it is the point of the enrichment); if length becomes a
  problem a future change can summarise, but not this one.
- The acknowledgement ledger is new local state. It is additive and safe to
  delete (a deleted ledger just re-surfaces every discovery once); it is not
  synced and not committed.
- Backoff parameters (`max_attempts`, base delay, cap) need concrete defaults in
  `.specforge/config.json`; execution picks values consistent with the existing
  `sync_interval_seconds` (30s) and `sync_lock_ttl_seconds` (120s).
