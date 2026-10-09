# Failure recovery

Run `./scripts/nogg doctor` first. It reports tool availability, locks,
mapping errors and the last sync failure without modifying data. Run
`./scripts/nogg audit` for the same invariant checks plus a timestamped
local report.

## Session helper or startup failures

`doctor` checks that `scripts/session-launch` and `scripts/session-log-writer`
are executable and implement the interface expected by the installed CLI.
A missing helper or incompatible contract means the managed payload is partial
or mixed. Run the pinned Nogging package's `update` from a release containing
the helper-contract repair, then run `./scripts/nogg doctor` again. Updating
from an older package that omitted the wrappers does not fix the installation.
Use the same distribution for the CLI and both helpers; do not patch wrapper
flags by hand. Existing worktrees need the repaired payload as well.

Contract refusal happens before tmux or session files, so it requires no session
cleanup. If a runtime starts and then exits, its record becomes `failed` and
its stderr is redacted and saved even if the pane disappears before logging
can attach. Run `./scripts/nogg session list`, then
`./scripts/nogg session log <name>` to inspect the underlying error (for example,
an unsupported runtime option or a missing executable). Fix that cause, retire
the terminal session with `session cleanup <name>`, and launch again. A quick
failure can occur just after the launcher returns; check the record and log
before assuming the agent is running.

Normal `update` replaces managed helpers while preserving OpenSpec, Beads,
custom profiles and unrelated agent settings. It does not upgrade the agent
CLI itself or grant additional authority.

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
| Materialized-but-uncommitted change | If the `.md` files are complete: commit them (`NOGGING_WRITER=planning`), re-run `./scripts/nogg materialize <change>` (idempotent — a leftover `materialize-<change>.json` journal names what is left), continue. If a `tasks.md` write was truncated: repair it against the Beads that exist, then commit. |
| Crashed session record | `./scripts/nogg session reap` then `./scripts/nogg session cleanup` (or `session cleanup --reap`); a still-live session is untouched. See § "A crashed or stuck supervised session". |
| Working tree mid-merge / mid-rebase | Finish or abort the operation before resuming; the sync timer skips while it is in progress. |

## A failed sync

Sync exit status distinguishes a complete/intentional no-op pass (`0`), a
repository-wide failure (`1`), and a degraded partial pass (`3`). A skipped
pass does not update the last-complete timestamp; inspect `last-skip.json`.

A partial pass quarantines every identifiable affected change and reconciles
independent valid changes. It writes `.nogging/state/sync-mapping-health.json`
with the last partial timestamp, processed/skipped changes, and current
per-change Bead IDs, reasons, first-seen and last-seen times. `doctor` names
both last complete and last partial passes and the age of each active scope.
The separate `last-success.json` changes only after a complete pass. Partial
passes do not schedule a repository-wide retry or repeat completed mirror
writes: rerunning is idempotent. After manual repair, rerun sync; only resolved
scopes clear, while the last partial pass remains as historical evidence.
Preserve a malformed health file and repair it before retrying: sync refuses
to overwrite unreadable durable health or mirror new evidence through it.

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
- **`permanent`** — repository-wide identity ambiguity, duplicate global task
  definitions, or unreadable durable mapping health. Identifiable mapping
  conflicts and missing tasks use the scoped degraded result above. Not retried
  automatically. Run `./scripts/nogg audit`, resolve the
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
Nogging adds no `bd dolt commit` checkpoint of its own in `sync` or
`materialize`; there is nothing uncommitted for it to flush. (Cross-machine
propagation is a separate concern — that is `bd dolt push` to a remote, which
the mechanical layer never does.)

## Diverged Dolt histories under multi-machine mode

With `multi_machine: true` (see `AGENTS.md` *Multi-machine mode*), two
machines writing Beads before either has pulled the other's commits becomes a
newly *likely* scenario — it was always possible, just unlikely without a
protocol encouraging concurrent local writes. `bd dolt push`/`pull` already
detect this and refuse rather than silently lose history: `bd` reports
**"Local and remote Dolt histories have diverged."**

Nogging does not add a second, parallel recovery procedure for this — follow
`bd`'s own guidance, printed under **"Recovery (bootstrap from one canonical
clone):"**: pick one machine's clone as canonical and re-bootstrap the others
from it. Re-bootstrapping a non-canonical clone discards its unpushed work, so
export anything not yet pushed from it first (`bd export`) before
re-bootstrapping. `./scripts/nogg doctor`'s "local Dolt is N commit(s) ahead
of its remote" NOTE is the earlier warning that heads this off — push from
each machine before another machine's session starts pulling.

## Discoveries closed before review

`./scripts/nogg discoveries` lists every `discovery`-labelled Bead
regardless of status, so a discovery closed before a planning session saw it is
not lost; closed ones are marked "awaiting review". After a planning session
acts on one, record it with `./scripts/nogg discoveries --ack <id>...` so
it stops resurfacing. The ledger
(`.nogging/state/acknowledged-discoveries.json`) is local and safe to delete.

## A crashed or stuck supervised session

`scripts/nogg session list` shows every Nogging-managed session and
reconciles each record against live tmux — a record still in an active state
whose tmux session is gone is shown as `failed`.

Start with **`scripts/nogg session reap`**: it moves every such vanished
record to the terminal `failed` state (a still-live session is left untouched),
which is what lets `session cleanup` retire it. `session cleanup --reap` does
the reap and the cleanup in one step.

- **Reported `failed`** — the metadata record is still active but the tmux
  session is gone (the process crashed or was killed outside Nogging). Read
  `session log <name>` for the last output, then `session reap` followed by
  `session cleanup` (or `session cleanup --reap`) to archive the log and retire
  the record.
- **Stuck / hung** — `session log <name> --follow` to see what it is doing,
  `session attach <name>` to intervene, or `session stop <name> --reason
  "<why>"` to interrupt Claude and terminate the tmux session. `stop` is
  idempotent and records `ended_at`/`exit_reason`.
- **`cleanup` refuses** — the record is still `starting`, `running` or `idle`.
  Run `session stop <name>` first; cleanup never acts on a live session.
- **Lingering tmux server** — the dedicated `-L nogg` server persists
  after its last session. `session cleanup` kills it once no non-retired
  record remains; otherwise `tmux -L nogg kill-server` by hand is safe
  when `session list` shows nothing active.
- **Lost metadata** — the records under `.nogging/state/sessions/` are local
  and safe to delete; deleting one only drops history for an already-finished
  session. A live tmux session with no record can be inspected directly with
  `tmux -L nogg attach -t <name>` and killed with `tmux -L nogg
  kill-session -t <name>`.

## A session hit its usage limit

`scripts/nogg session watch` classifies a session that has hit an account-wide
usage limit as `limit`, carrying the resolved reset time as `until=<ISO8601>`
in the event. `scripts/nogg session resume-when-ready <name>` waits out that
timestamp (never a tight poll loop) and sends a resume instruction once the
limit clears — no operator action required.

**Switching models does not clear this.** A usage limit observed in
production is account-wide, not per-model: picking a cheaper or faster model
does not bypass it (confirmed twice in production, GitHub issue #20).
`resume-when-ready` dismisses a residual "switch model?" prompt by keeping the
current model, never by switching to one. If a session is stuck on a usage
limit, wait it out (or run `resume-when-ready`) — do not spend a session-cycle
retrying with a different model.

## `openspec/` stuck read-only or stuck writable

The canonical boundary lives in the **main checkout's** `.nogging/locks`,
shared by linked worktrees. Run `./scripts/nogg repo-state --cwd "$PWD"` to
resolve the exact paths; `doctor` prints them. Unsupported or unavailable Git
metadata denies authorization. Do not create a local lock as a substitute.

Pi permits OpenSpec writes only for an explicit planning role with a valid,
fresh canonical `planning.lock` and no closed sentinel. The main checkout's
`planning_lock_ttl_seconds` applies (default 7200); invalid values, future
locks, unreadable state and dangling sentinel symlinks deny authorization.
Execution roles remain read-only while another planning session is open.

- **Stuck read-only:** inspect canonical state and confirm the lock owner.
  Use `plan-begin` only in the authorized planning workflow. Use `--force`
  only after confirming the stale owner is gone. A legacy worktree-local
  `openspec.readonly` also closes Pi's boundary: prefer a fresh worktree, or
  remove the legacy sentinel only after confirming no live owner needs it.
  Deleting the canonical sentinel alone does not authorize Pi writes.
- **Stuck writable:** run `plan-end` to release the lock and restore the
  canonical sentinel. If the lock is absent, `plan-end --force` closes the
  boundary. Check `doctor` again; never grant an execution role planning
  authority to work around a guard failure.

Discovery acknowledgements share the main checkout's
`.nogging/state/acknowledged-discoveries.json`. Invoking a legacy worktree
merges its IDs under an exclusive lock and preserves source snapshots in
`acknowledged-discoveries.backups/` before atomic replacement. Malformed or
unreadable ledgers refuse the operation rather than erase IDs. Preserve the
original file, inspect the reported source and recovery snapshots, then repair
or restore a valid ledger with all known acknowledged IDs and original
timestamps. Retry `discoveries`; never infer acknowledgements from Bead status.
An interrupted replacement leaves the previous ledger usable; retry normally.

## Non-task follow-ups and trace-preserving mapping repair

Use a regular materialized Bead for work that implements an approved task.
For related work that has no approved checkbox, create an explicit non-task
follow-up, retaining the change association and a human explanation:

```bash
bd create "Investigate related behavior" --type task \
  --labels "openspec:followup,openspec:change:<change-name>" \
  --description "What remains, the evidence, and why this is a non-task follow-up."
```

Do not copy an existing task label onto the follow-up. If it must block mapped
work, add the dependency explicitly in the correct direction:

```bash
bd dep add <mapped-bead-id> <followup-bead-id> --type blocks
```

An open or blocked follow-up without that edge does not prevent completion of
the mapped change. Nonblocking traceability edges do not substitute for
`blocks`. A missing or unreadable blocking prerequisite prevents completion.
Follow-ups are never mirrored to an invented task or execution-log entry.

For a malformed mapping, first inspect the named Bead, its notes/commit
history, the approved task definition and every other Bead with the same task
label. Establish which Bead is the canonical mapped task. In a deliberate
planning repair, either restore the correct unique mapping or classify the
extra work as a follow-up: remove its erroneous task label, retain the one
correct change label, and add `openspec:followup`. Record the reason and the
canonical Bead ID in a human note. Preserve closure status, commit evidence,
discoveries and dependency edges; never delete a closed Bead to make audit pass.
Conflicting change labels need an explicit ownership decision before repair.

Run `./scripts/nogg audit` again, then `./scripts/nogg materialize <change>`
for any missing approved work and `./scripts/nogg sync --now` to reconcile.
Audit remains nonzero while any defect exists. A scoped defect allows unrelated
valid changes to proceed with degraded exit `3`; duplicate global task IDs,
ambiguous tracker identities or unreadable tracker state refuse every mirror
write. See the partial-pass health section above to confirm repaired scopes
have cleared without losing historical diagnostics.

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
