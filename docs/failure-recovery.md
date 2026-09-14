# Failure recovery

Run `./scripts/nogg doctor` first. It reports tool availability, locks,
mapping errors and the last sync failure without modifying data. Run
`./scripts/nogg audit` for the same invariant checks plus a timestamped
local report.

## Resuming an interrupted run

A planning or development run can stop mid-way — the token budget runs out, the
process crashes, the SSH session drops, or the operator switches tools. On the
next start — fresh, resumed, or after a tool switch — every agent runs
`./scripts/nogg recover` **before** `bd ready` (see `AGENTS.md` §
"Resuming a run"), then resolves what it reports with this playbook:

| `recover` reports | Action |
| --- | --- |
| Stale `planning.lock` | Confirm no planning session is actually running, then `./scripts/nogg plan-end --force`. |
| Fresh `planning.lock`, not yours | A planning session is active elsewhere. Do not start execution that depends on unmaterialized work — wait or coordinate. |
| `LIMBO: <id> committed … but status=<status>` | The work is **done**. `git show` the commit, run `scripts/test`, add the evidence note (`bd update <id> --append-notes "commit <sha>; <evidence>"`), `bd close <id>`. **Do not re-implement it** — that produces a duplicate commit. |
| `in_progress` Bead, `resumable` | Same as `LIMBO`: it has a commit, so the work is done — verify, note, close. Never re-implement. |
| `in_progress` Bead, `stale`, with a diff | Decide: finish the uncommitted diff, or `git stash` it and re-claim clean. Record the decision in the Bead note. |
| `in_progress` Bead, `stale`, no diff | Likely never started. Re-claim and work it normally. |
| Orphan Bead | Planning session only: restore the task line, or cancel the Bead with a recorded reason (§ "Orphaned Beads and bad mirrors"). An execution agent stops and reports it. |
| Materialized-but-uncommitted change | If the `.md` files are complete: commit them (`SPECFORGE_WRITER=planning`), re-run `./scripts/nogg materialize <change>` (idempotent — a leftover `materialize-<change>.json` journal names what is left), continue. If a `tasks.md` write was truncated: repair it against the Beads that exist, then commit. |
| Crashed session record | `./scripts/nogg session reap` then `./scripts/nogg session cleanup` (or `session cleanup --reap`); a still-live session is untouched. See § "A crashed or stuck supervised session". |
| Working tree mid-merge / mid-rebase | Finish or abort the operation before resuming; the sync timer skips while it is in progress. |

## A failed sync

A failed sync writes `.nogging/state/sync-failure.json` and appends the same
data to `.nogging/state/sync-failures.jsonl` (a retained history). `doctor`
prints the active record: its `classification`, the `attempts` / `max_attempts`
count, and `next_retry_after`.

- **`transient`** — lock contention, or a `git` / `bd` / JSON error. The timer
  retries automatically with capped exponential backoff until `max_attempts`
  (`sync_max_attempts`, `sync_retry_base_seconds`, `sync_retry_cap_seconds` in
  `.nogging/config.json`). Usually no action is needed; if it keeps failing,
  read the `error` field and clear the blockage (for example a genuinely stale
  `.nogging/locks/sync.lock`).
- **`permanent`** — a failed invariant audit, a mapping conflict, or a missing
  task. Not retried automatically. Run `./scripts/nogg audit`, resolve the
  disagreement in Beads or `openspec/` (a planning session for the latter),
  then rerun `./scripts/nogg sync`.

A successful sync deletes the active record; the JSONL history stays. Sync is
idempotent — closed-Bead mirroring is gated by the per-closure event key and
the checkbox rewrite only flips `- [ ]` to `- [x]` — so a retry is always safe.
Do not edit the execution log or its event keys by hand.

For a stale planning lock, confirm its process is gone and run
`./scripts/nogg plan-end --force`.

## The sync keeps skipping

The timer-driven `sync` refuses to mirror when the repository is not a safe
place to commit, and a skip is a no-op — no failure record, so `sync-failure.json`
stays empty. If closed Beads are not being mirrored, run
`./scripts/nogg doctor`: a `NOTE  last sync skipped: <reason> (<age>)` line
names why the most recent tick skipped. The reasons and their fixes:

- **`on protected branch <b>`** — `HEAD` is on `main` or `develop`. Move to a
  change branch (the operating model: one branch per change) and the next tick
  mirrors normally, or run `./scripts/nogg sync --now` for a deliberate
  one-off catch-up on that branch. To change the policy, edit
  `sync_protected_branches` in `.nogging/config.json` (an operator who really
  does day-to-day work on `develop` can set it to `["main"]`).
- **`planning session active`** — a planning session holds `planning.lock`.
  This is deliberate; the mirror resumes after `plan-end`. If the lock is stale,
  `./scripts/nogg plan-end --force`.
- **`<op> in progress`** (merge / rebase / cherry-pick / bisect) — finish or
  abort the operation; the next tick then mirrors. `sync --now` also refuses
  this one.
- **`detached HEAD`** — check out a branch.

`last-skip.json` is cleared automatically by the next real or no-op sync; it is
local and safe to delete.

## Bead durability across a crash

Bead state is durable the moment a `bd` command returns. `bd` auto-commits every
mutating command (`create`, `update`, `claim`, `close`, …) to Dolt *history* —
each is its own Dolt commit (`bd: close SPEC-x`), not a change left sitting in
the working set. Verified against this repo's shared Dolt server: the `issues`
table working set stays clean while `dolt_log` grows one commit per write.

So the in-scope interruptions — a process crash, token exhaustion, an SSH drop —
never lose a recorded Bead change: whatever `bd` reported is already committed.
SpecForge adds no `bd dolt commit` checkpoint of its own in `sync` or
`materialize`; there is nothing uncommitted for it to flush. (Cross-machine
propagation is a separate concern — that is `bd dolt push` to a remote, which
the mechanical layer never does.)

## Discoveries closed before review

`./scripts/nogg discoveries` lists every `discovery`-labelled Bead
regardless of status, so a discovery closed before a planning session saw it is
not lost; closed ones are marked "awaiting review". After a planning session
acts on one, record it with `./scripts/nogg discoveries --ack <id>...` so
it stops resurfacing. The ledger
(`.nogging/state/acknowledged-discoveries.json`) is local and safe to delete.

## A crashed or stuck supervised session

`scripts/nogg session list` shows every SpecForge-managed session and
reconciles each record against live tmux — a record still in an active state
whose tmux session is gone is shown as `failed`.

Start with **`scripts/nogg session reap`**: it moves every such vanished
record to the terminal `failed` state (a still-live session is left untouched),
which is what lets `session cleanup` retire it. `session cleanup --reap` does
the reap and the cleanup in one step.

- **Reported `failed`** — the metadata record is still active but the tmux
  session is gone (the process crashed or was killed outside SpecForge). Read
  `session log <name>` for the last output, then `session reap` followed by
  `session cleanup` (or `session cleanup --reap`) to archive the log and retire
  the record.
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
- **Lost metadata** — the records under `.nogging/state/sessions/` are local
  and safe to delete; deleting one only drops history for an already-finished
  session. A live tmux session with no record can be inspected directly with
  `tmux -L specforge attach -t <name>` and killed with `tmux -L specforge
  kill-session -t <name>`.

## `openspec/` stuck read-only or stuck writable

The OpenSpec write boundary is a sentinel file,
`.nogging/locks/openspec.readonly`, plus a per-session read-only `openspec/`
root for launched execution sessions. `./scripts/nogg doctor` prints its
state (`openspec write boundary: OPEN` / `LOCKED` / `LOCKED (stale planning lock
present …)`).

- **Stuck read-only** — a planning session cannot edit `openspec/` because a
  sentinel was left behind or `plan-begin` crashed. Run
  `./scripts/nogg plan-begin` (add `--force` if a stale planning lock
  lingers); it removes the sentinel and opens the boundary. Deleting
  `.nogging/locks/openspec.readonly` by hand has the same effect on the
  `PreToolUse` fast path — the sentinel is local, additive state and safe to
  delete.
- **Stuck writable** — a forgotten `plan-end` left `openspec/` open. Run
  `./scripts/nogg plan-end` (add `--force` if the planning lock is already
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
and `./scripts/nogg validate` reads archived `tasks.md` files (date prefix
stripped back to the change name) so those closed Beads keep resolving.
Archiving a completed change is supported and keeps the audit clean; `sync` and
`materialize` continue to ignore the archive directory. If `validate` ever
reports "maps missing task" for a Bead whose change directory now lives under
`archive/`, check that the archived `tasks.md` still contains the task line.
