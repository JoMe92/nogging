# Failure recovery

Run `./scripts/specforge doctor` first. It reports tool availability, locks,
mapping errors and the last sync failure without modifying data. Run
`./scripts/specforge audit` for the same invariant checks plus a timestamped
local report.

## A failed sync

A failed sync writes `.specforge/state/sync-failure.json` and appends the same
data to `.specforge/state/sync-failures.jsonl` (a retained history). `doctor`
prints the active record: its `classification`, the `attempts` / `max_attempts`
count, and `next_retry_after`.

- **`transient`** — lock contention, or a `git` / `bd` / JSON error. The timer
  retries automatically with capped exponential backoff until `max_attempts`
  (`sync_max_attempts`, `sync_retry_base_seconds`, `sync_retry_cap_seconds` in
  `.specforge/config.json`). Usually no action is needed; if it keeps failing,
  read the `error` field and clear the blockage (for example a genuinely stale
  `.specforge/locks/sync.lock`).
- **`permanent`** — a failed invariant audit, a mapping conflict, or a missing
  task. Not retried automatically. Run `./scripts/specforge audit`, resolve the
  disagreement in Beads or `openspec/` (a planning session for the latter),
  then rerun `./scripts/specforge sync`.

A successful sync deletes the active record; the JSONL history stays. Sync is
idempotent — closed-Bead mirroring is gated by the per-closure event key and
the checkbox rewrite only flips `- [ ]` to `- [x]` — so a retry is always safe.
Do not edit the execution log or its event keys by hand.

For a stale planning lock, confirm its process is gone and run
`./scripts/specforge plan-end --force`.

## Discoveries closed before review

`./scripts/specforge discoveries` lists every `discovery`-labelled Bead
regardless of status, so a discovery closed before a planning session saw it is
not lost; closed ones are marked "awaiting review". After a planning session
acts on one, record it with `./scripts/specforge discoveries --ack <id>...` so
it stops resurfacing. The ledger
(`.specforge/state/acknowledged-discoveries.json`) is local and safe to delete.

## A crashed or stuck supervised session

`scripts/specforge session list` shows every SpecForge-managed Claude session
and reconciles each record against live tmux.

- **Reported `failed`** — the metadata record is still active but the tmux
  session is gone (the Claude process crashed or was killed outside SpecForge).
  Read `session log <name>` for the last output, then `session cleanup <name>`
  to archive the log and retire the record.
- **Stuck / hung** — `session log <name> --follow` to see what it is doing,
  `session attach <name>` to intervene, or `session stop <name> --reason
  "<why>"` to interrupt Claude and terminate the tmux session. `stop` is
  idempotent and records `ended_at`/`exit_reason`.
- **`cleanup` refuses** — the record is still `starting`, `running` or `idle`.
  Run `session stop <name>` first; cleanup never acts on a live session.
- **Lingering tmux server** — the dedicated `-L specforge` server persists
  after its last session. `session cleanup` kills it once no non-retired
  record remains; otherwise `tmux -L specforge kill-server` by hand is safe
  when `session list` shows nothing active.
- **Lost metadata** — the records under `.specforge/state/sessions/` are local
  and safe to delete; deleting one only drops history for an already-finished
  session. A live tmux session with no record can be inspected directly with
  `tmux -L specforge attach -t <name>` and killed with `tmux -L specforge
  kill-session -t <name>`.

## `openspec/` stuck read-only or stuck writable

The OpenSpec write boundary is a sentinel file,
`.specforge/locks/openspec.readonly`, plus a per-session read-only `openspec/`
root for launched execution sessions. `./scripts/specforge doctor` prints its
state (`openspec write boundary: OPEN` / `LOCKED` / `LOCKED (stale planning lock
present …)`).

- **Stuck read-only** — a planning session cannot edit `openspec/` because a
  sentinel was left behind or `plan-begin` crashed. Run
  `./scripts/specforge plan-begin` (add `--force` if a stale planning lock
  lingers); it removes the sentinel and opens the boundary. Deleting
  `.specforge/locks/openspec.readonly` by hand has the same effect on the
  `PreToolUse` fast path — the sentinel is local, additive state and safe to
  delete.
- **Stuck writable** — a forgotten `plan-end` left `openspec/` open. Run
  `./scripts/specforge plan-end` (add `--force` if the planning lock is already
  gone) to re-close it. `doctor` surfaces the open boundary meanwhile; a
  launched execution session is unaffected because it keys its read-only root
  off its own role, and the stale-lock TTL eventually re-closes the `PreToolUse`
  path on its own.

## Orphaned Beads and bad mirrors

If an active Bead is orphaned, the planner must either restore/relink its task
or cancel the Bead with a recorded reason. Never delete a closed Bead. Roll back
an incorrect execution-log update with a normal Git revert and then rerun sync.

A closed Bead whose change has been **archived** is not orphaned. `openspec
archive <name>` moves the change to `openspec/changes/archive/YYYY-MM-DD-<name>/`,
and `./scripts/specforge validate` reads archived `tasks.md` files (date prefix
stripped back to the change name) so those closed Beads keep resolving.
Archiving a completed change is supported and keeps the audit clean; `sync` and
`materialize` continue to ignore the archive directory. If `validate` ever
reports "maps missing task" for a Bead whose change directory now lives under
`archive/`, check that the archived `tasks.md` still contains the task line.
