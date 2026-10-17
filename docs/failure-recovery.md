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

Contract refusal happens before backend or session files, so it requires no session
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
| Stale `planning.lock` | Confirm no planning session is actually running, then `./scripts/nogg plan-end --force`. A lock that names a supervised session is refused while that owner is alive; `recover` names the owner. Never release another session's lock by stopping or cleaning up your own. To release a stopped planner's own lock, run `./scripts/nogg session stop <name>` (see *A planning worktree whose cleanup is refused*). |
| Fresh `planning.lock`, not yours | A planning session is active elsewhere. Do not start execution that depends on unmaterialized work — wait or coordinate. |
| Stale `orchestrator.lock` | The lock holder's process is verified dead or start time mismatched (or expired on a remote host). Reclaim with `./scripts/nogg orchestrator run --force` or restart the supervisor. An unverifiable holder (fenced caller or foreign PID namespace) is never reported stale. |
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

## A planning worktree whose cleanup is refused

`plan-end` always precedes worktree retirement, so a planner that has run
`plan-end` has already released its lock; only the worktree remains.
`./scripts/nogg worktree cleanup <record>` refuses, before removing anything,
when the worktree, a path under it or its Git directory appears in
`/proc/self/mountinfo` (a Codex planner's sandbox mounts its own worktree),
when the caller's working directory is inside it, when another active session
record works there, or when the mount table cannot be read. A refusal changes
no file, branch or record. Do not retry it, force it or delete files by hand.

1. Hand off: `./scripts/nogg session stop <name>`, then
   `./scripts/nogg worktree cleanup <record>` from the canonical checkout. The
   operator or the Orchestration Agent runs both. For a Codex planner this is
   the normal end.
2. `session stop` of the owning planner waits within its grace period for the
   owner to exit and then releases that session's planning lock without
   `plan-end --force`. If the owner is still live afterwards the lock is kept,
   and the message names `session stop <name>` to rerun once it has exited.
   `recover` names the same step for an interrupted owner that still has a
   session record.
3. If an older build's partial `git worktree remove` already deleted tracked
   files from the worktree, restore them with
   `git -C <worktree> restore --source=HEAD --worktree -- .`, then run the
   cleanup again.

## A crashed or stuck supervised session

`scripts/nogg session list` shows every Nogging-managed session and
reconciles each record against its live backend session (tmux or herdr) — a record
still in an active state whose backend session is gone is shown as `failed` (or with
unknown liveness if the backend tool fails).

Start with **`scripts/nogg session reap`**: it moves every such vanished
record to the terminal `failed` state (a still-live session is left untouched),
which is what lets `session cleanup` retire it. `session cleanup --reap` does
the reap and the cleanup in one step.

- **Reported `failed`** — the metadata record is still active but the backend
  session is gone (the process crashed, the herdr server restarted, or the
  session was killed outside Nogging). Read `session log <name>` for the last
  output, then `session reap` followed by `session cleanup` (or
  `session cleanup --reap`) to archive the log and retire the record.
- **Stuck / hung** — `session log <name> --follow` to see what it is doing,
  `session attach <name>` to intervene, or `session stop <name> --reason
  "<why>"` to interrupt the agent and terminate the backend session. `stop` is
  idempotent and records `ended_at`/`exit_reason`.
- **`cleanup` refuses** — the record is still `starting`, `running` or `idle`.
  Run `session stop <name>` first; cleanup never acts on a live session.
- **Lingering session servers** — on tmux, the dedicated `-L nogging` server persists
  after its last session. `session cleanup` calls `idle_shutdown()` (`kill-server`)
  **only** when its `list-sessions` query succeeds and reports no sessions on the
  dedicated server. It never kills a server that still hosts foreign checkouts' sessions
  or the always-on Orchestration Agent (`nogg-orchestrator-*`), even if all records of the
  local checkout are retired. On herdr, Nogging starts a dedicated headless herdr server
  on demand and never kills it during cleanup. Note that a herdr server restart terminates
  all Nogging herdr sessions; restored panes matching a retired record of this checkout
  are closed by `session cleanup` (while foreign panes matching no local record are left
  untouched).
- **Lost metadata** — the records under `.nogging/state/sessions/` are local
  and safe to delete; deleting one only drops history for an already-finished
  session. An orphaned live tmux session with no record can be inspected directly
  with `tmux -L nogging attach -t <name>` and killed with `tmux -L nogging
  kill-session -t <name>`.

## Tmux server born in a sandbox

If a shared tmux server was started inside an OpenSpec execution sandbox (for
example, if an agent ran `tmux -L nogging new-session` directly without `-N`
prior to the fenced server refusal), that server lives inside the sandboxed
caller's PID and mount namespaces:

- **Symptom:** Every session hosted on that tmux server terminates abruptly
  together when the hosting sandboxed Lead exits or its container/namespace is
  destroyed. The server also inherits the sandbox's read-only mount of
  `openspec/`.
- **Diagnosis:**
  - `doctor` reports an advisory WARN naming the server PID:
    `WARN  dedicated tmux server (-L nogging) runs inside sandbox PID <pid>; all hosted sessions terminate when that namespace exits`
    (the WARN does not change `doctor`'s exit code).
  - `session list` prints one `NOTE` advisory when the server is sandboxed.
  - `orchestrator status` reports the server classification under `tmux server: sandboxed`
    (instead of `host`, `outside`, `down`, or `unknown`).
  - `orchestrator run` and unsandboxed `session launch` print a warning when
    they start or adopt a session on a sandboxed server, and then continue.
- **Operator choices:** Nogging never kills, restarts, or signals the server
  automatically. The operator can choose:
  1. *Let the Lead finish:* If active work on the server is progressing well,
     let the hosting session run to completion; sessions continue until that
     sandbox exits.
  2. *Stop the server deliberately:* If long-term stability is needed, stop the
     server explicitly from an unsandboxed shell with `tmux -L nogging kill-server`
     (knowing that every session hosted on it ends), and then start a fresh
     session or the Orchestration Agent from the host so the new server is born
     in the host namespace.

## Herdr server down and recovery

If the dedicated herdr server stops, crashes, or is killed:
1. **Definite down state:** Nogging checks two independent sources:
   - `herdr --session <ns> status` reports `server: status: not running`.
   - `herdr session list --json` reports `running: false`.
   When both answers agree, Nogging concludes with certainty that the server is down.
   Its session records are classified as `vanished` (rendered as `failed` in `session list`),
   which allows `session reap` to mark them failed and `session cleanup` to retire them.
   A subsequent launch for the same Bead is no longer blocked by false "a live lead session
   already covers" errors.
2. **Restarting the server:** Run the idempotent host-side command:
   ```bash
   ./scripts/nogg session herdr-server start
   ```
   This command starts the headless server with Nogging's scrubbed environment, immutable
   config, and ownership receipt.
   - **Fenced callers cannot start the server:** If a sandboxed Lead (or any process
     with `NOGG_OPENSPEC_FENCED=1`) attempts to launch while the server is down, launch
     is refused before any side effect. The Lead must ask the operator or Orchestration
     Agent to start the server host-side via `session herdr-server start`.
   - **Unowned running servers:** If a running server fails ownership checks (differing
     config or mismatched socket identity), `session herdr-server start` refuses and names
     the failed check. Stop the unowned server manually with `herdr --session <ns> server stop`;
     Nogging never stops or kills an unowned herdr server itself.

## Orchestrator lock states and holder liveness

The Orchestration Agent is protected by `.nogging/locks/orchestrator.lock`, which records
`{pid, host, created_at, pid_start, pid_ns}`. A single shared classifier evaluates lock
staleness for `orchestrator run`, `orchestrator status`, `recover`, and `doctor`.

Rather than relying purely on a timestamp timeout, staleness is strictly bound to holder
liveness across PID namespaces:

| Holder as seen by caller | State | Stale? | Action in `recover` |
| --- | --- | --- | --- |
| Same host & same PID namespace; PID alive with matching `pid_start` | `held (verified)` | **No** (never stale at any age) | Valid live lock. No attention item. |
| Same host & same namespace; PID gone or start time mismatch | `dead` | **Yes** | Attention item: stale lock. Reclaim with `orchestrator run --force` or restart service. |
| Legacy lock (no `pid_start`); PID alive running `nogg … orchestrator run` | `held (verified)` | **No** (never stale) | Valid live legacy holder. No attention item. |
| Legacy lock; PID alive but running another command (reused PID) | `dead` | **Yes** | Attention item: PID reused. Reclaim with `orchestrator run --force`. |
| Same host, but foreign or unobservable PID namespace, or fenced caller (`NOGG_OPENSPEC_FENCED=1`) | `held (unverifiable)` | **No** | Displayed as held (unverifiable). **No attention item**, exits 0 (fenced callers cannot verify host PIDs). |
| Another host | `held (unverifiable)` / `stale` | Only if age ≥ `orchestrator_lock_ttl_seconds` | Stale only when older than TTL (default 86400s). Reclaim if host is gone. |

Consequently:
- An actively running Orchestration Agent on the host is **never** considered stale, even if its lock is months old.
- A sandboxed Lead running `recover` cannot observe host PIDs, so it treats the lock as `held (unverifiable)` rather than falsely reporting it dead.
- `recover` raises an attention item and exits non-zero only when a lock is genuinely stale (dead holder or expired cross-host).

### Orchestrator lock in linked worktrees

The orchestrator lock and identity are strictly canonical:
- **Canonical resolution:** The orchestrator lock path `<main>/.nogging/locks/orchestrator.lock`,
  the repository slug `<slug>`, the systemd user service `nogg-orchestrator-<slug>.service`,
  and live session lookup are always resolved from the repository's **main checkout**
  (`canonical_repository_state(ROOT)`), regardless of which linked worktree runs the command.
- **Worktree visibility:** Running `orchestrator status`, `doctor`, or `recover` inside a linked
  worktree inspects the main checkout's lock and live session, correctly reporting the
  orchestrator as held or stale. It never falsely reports the lock as free.
- **Run refusal:** `scripts/nogg orchestrator run` invoked from a linked worktree refuses
  before taking any lock and names the main checkout, preventing duplicate orchestrators.
  `orchestrator status`, `stop` and `restart` act on the canonical unit from any checkout.
- **Leftover worktree locks:** Any checkout-local `orchestrator.lock` file in a linked
  worktree is ignored and never read as the true lock. `recover` and `doctor` report it
  as an advisory NOTE with its path.

## `task-done` asking for a relaunch

When running `./scripts/nogg task-done <bead-id>` inside a sandboxed session whose
host-side broker predates checkout-aware requests:

- **Symptom:** `task-done` fails and prints:
  ```text
  task-done: this session's sandbox broker predates checkout-aware ticks; relaunch the session and run task-done again; nothing was ticked
  ```
- **Cause:** To ensure checkbox ticks land in the exact implementation worktree
  where the Bead was executed, `task-done` transmits `{"bead_id", "checkout"}` to
  `NOGG_TASK_DONE_SOCKET`. An older broker daemon rejects requests containing the
  checkout field with `only one closed Bead identifier`.
- **Behavior:** The client sends exactly one request. Upon receiving the pre-update
  refusal, it exits non-zero without retrying (a retry omitting `checkout` would
  erroneously tick the launch checkout) and never falls back to a local tick
  (because `openspec/` is read-only inside the execution sandbox).
- **Recovery:** Relaunch the supervised session under the updated host-side broker,
  then re-run `task-done <bead-id>`. Alternatively, the tick will be mirrored
  automatically by the sync timer or an unsandboxed sync run once the Bead is closed.

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
