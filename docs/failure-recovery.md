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

- **Startup readiness timeouts and hook diagnosis:** `session kickoff` and plain
  `session send` wait boundedly up to `session_startup_timeout_seconds` (default 120s)
  for a session to become ready for input. If startup readiness times out:
  - For Claude, check if the session is still connecting to Remote Control or
    blocked on an interactive prompt;
  - For Codex, inspect the session for trust or approval dialogs;
  - For Antigravity, check if the startup turn finished but failed to emit a `Stop`
    hook event (verify `.agents/hooks.json` and `scripts/hooks/agy-guard` with
    `./scripts/nogg doctor`), or if a feedback survey is active in the pane;
  - Do not blindly resend or type speculative keys; inspect the pane with
    `nogg session attach <name>` or check `nogg session log <name>` and `watch`.
- **Unverified delivery and deliberate recovery:** When `session send`, `nudge`,
  or `kickoff` reports an **unverified** outcome (for instance, a message accepted
  by `codex queue` without a matching transcript receipt or confirmed composer
  transition within `session_delivery_timeout_seconds`):
  - Do not immediately reissue the send command; automated re-sending or blind
    pane typing is refused to prevent duplicate instructions.
  - Inspect the session log (`nogg session log <name> --follow`) or attach to the
    pane to observe whether the agent received and is working on the instruction.
  - If the instruction remained pending in the composer, use deliberate recovery
    with `./scripts/nogg session nudge <name> --message "<instruction>"` to
    cleanly replace and resubmit it with bounded verification.

Normal `update` replaces managed helpers while preserving OpenSpec, Beads,
custom profiles and unrelated agent settings. It does not upgrade the agent
CLI itself or grant additional authority.

### Older vendored session helpers

If a vendored Nogging copy shows older session symptoms, update the copy to
3.0.0 or later. The reliable-session-input fixes shipped in 3.0.0 (changelog
items #207, #216 and #218): Nogging
recognizes Claude's `[Pasted text #N]` as this operation's pending paste only
when its composer was verified empty first; it waits for Claude and
Antigravity (experimental) startup readiness before sending input; and it
delivers and verifies kickoff, requiring fresh receipt evidence after a Codex
queue accepts a message. An unconfirmed outcome is unverified, not
delivered. The launch-name and Codex delivery safeguards also require a Nogging
update containing the launch-name/Codex-delivery change; changing only the
agent CLI does not install them. Use the repository's pinned Nogging `update`
procedure, then inspect any `.nogging-new` files and reconcile them as
described above.

Generated session names replace `.` and `:` with `_` so tmux and herdr address
the same safe name as the session record. When launch fails before `running`,
Nogging cleans up the session it created and records the cleanup result. If a
Codex planner's pane PID is invisible from the launcher's PID namespace, the
wrapper receipt supplies the identity; a missing or mismatched receipt makes
the planner launch fail and clean up rather than leave an unusable planning
session. See the running-work-in-sessions and using-with-codex guides in the
repository's `docs/` directory for the operator procedures.

## Locally modified files and pending `.nogging-new` updates

When updating a repository where verbatim managed files (such as
`.codex/rules/nogging.rules` or `.nogging/launch-prompts/orchestrator.md`) were
customized locally, Nogging preserves the local modifications and writes the
upstream release content to `<file>.nogging-new`.

- **Doctor warning:**
  `./scripts/nogg doctor` reports any pending files as:
  ```text
  WARN  locally modified file has pending upstream update: <path> (review <path>.nogging-new and reconcile)
  ```
  The warning is advisory and does not cause `doctor` to exit with an error. If
  `<file>.orig` backup files are present from a previous `--force` update, `doctor`
  also notes them:
  ```text
  NOTE  --force backup of a locally modified file: <path>.orig (delete it once reviewed)
  ```
- **Reconciliation workflow:**
  1. Inspect the differences between your customized file and the incoming release:
     ```bash
     diff -u <file> <file>.nogging-new
     ```
  2. Merge the desired upstream changes into `<file>`.
  3. Delete `<file>.nogging-new` once reconciled:
     ```bash
     rm <file>.nogging-new
     ```
- **Overwriting local modifications (`--force`):**
  If you prefer to accept upstream changes unconditionally and discard local edits,
  re-run update with `--force`:
  ```bash
  npx github:JoMe92/nogging#<tag> update --force
  ```
  Nogging creates a backup of your local file at `<file>.orig` and overwrites
  `<file>` with the upstream version. Once verified, remove `<file>.orig`.


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
| `LIMBO: <id> committed … but status=<status>` | The Bead has committed work: all of it, or only its first steps (a Bead committed in several steps shows `(newest of N token commits)`). List the commits (`git log --oneline --grep '\[<id>\]'`) and compare them with the task slice. Finish anything still missing from the last commit on. Once it is complete, run the affected suite (the full suite is CI's job; `scripts/test` only where the project has no CI), add the evidence note listing every commit SHA (`bd update <id> --append-notes "commits <sha>, <sha>; <evidence>"`), and `bd close <id>`. **Do not re-implement committed work** — that produces duplicate commits. |
| A Bead or worktree marked `owned by session <name>` | Another Lead is running on it, so it is not yours to adopt. Leave its worktree, branch, commits and notes alone, even if it looks unfinished, and report it instead. It raises no attention unless that Lead signalled `blocked`, when a person decides. A Lead proven dead holds nothing, so its Bead reads as an ordinary interrupted run. A session's own Bead is not marked. |
| A Bead marked `session <name> may still be running` | Its liveness could not be established. Confirm the session ended (`./scripts/nogg session reap`) before adopting the Bead. |
| `in_progress` Bead, `resumable` | Same as `LIMBO`: it has committed work. Check what is complete, finish what is missing, then verify, note and close. Never re-implement. |
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
the working set. Verified against a shared Dolt server: the `issues`
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

## A scheduled loop stopped running

Start with `./scripts/nogg doctor` and `./scripts/nogg loop log <name>`.

- **`will not run`**: the timer is missing or disabled. Link its service and enable
  it as the [timer section](scheduled-loops.md#the-scheduler-timer) shows, or run
  `nogg loop tick` from your own scheduler.
- **`unknown from this session`**: `systemctl` is denied in this session, so
  `doctor` cannot read the timer; check it from a shell outside the session.
- **The last tick is old**: read the service journal.
- **`doctor` fails on the definitions file**: no new run starts until it is fixed.
  Ticks keep running and keep supervising started runs.
- **`suspended`**: consecutive slots failed. Read the reasons, fix the cause, then
  run `nogg loop resume <name>`.
- **A run stays active past `max_runtime`**: its session could not be retired, and
  the tick retries every minute, even while the definitions file is invalid.
  Never delete `state.json` to clear it, because the session would be orphaned.
  Fix what the journal reports.
- **A session listed as `loop:<name>` is left after a crash**: wait 10 minutes.
  The tick adopts it by `loop_run_id` if its kickoff landed, or else stops and
  retires it and logs `start interrupted`.

See [Scheduled loops](scheduled-loops.md).

## Session dispatch is silent or holds its digest

Session dispatch is on by default, and a missing orchestrator or timer is no failure.
`doctor` says which applies.

- **`session dispatch: no orchestrator session`**: the items are held, not lost. Run
  `nogg orchestrator run`, and the items that still hold go out as one digest.
- **`session dispatch: nothing fires a pass automatically`**: the loops timer is off.
  Enable it as the [timer section](scheduled-loops.md#the-scheduler-timer) shows, or run
  `nogg session dispatch --once` from your own scheduler.
- **`WARN session dispatch: ... is enabled but the last pass was at ...`**: read
  `journalctl --user -u nogg-loops-<slug>.service` for `the dispatch pass failed`. A
  failed pass never stops the loops, and neither do the loops stop a pass.
- **A digest stays queued**: `nogg session inbox` names the hold. A pause, quiet hours,
  a busy orchestrator, typed input in its prompt and the usage hold all keep it queued,
  and each clears by itself.
- **`queue.json` or `state.json` was unreadable**: the pass moves it aside as
  `*.corrupt`, logs that in `.nogging/state/dispatch/dispatch.jsonl` and starts clean.
  Live conditions come back on the next pass, because they are read from real state.

To stop it, pause with `nogg pause` or set `session_dispatch.enabled: false`. See
[Session wake](session-wake.md).

## A session hit its usage limit

`scripts/nogg session watch` classifies a session that has hit an account-wide
usage limit as `limit`, carrying the resolved reset time as `until=<ISO8601>`
in the event. `scripts/nogg session resume-when-ready <name>` waits out that
timestamp (never a tight poll loop) and sends a resume instruction once the
limit clears — no operator action required.

**Switching models does not clear this.** A usage limit observed in
production is account-wide, not per-model: picking a cheaper or faster model
does not bypass it (confirmed twice in production).
`resume-when-ready` dismisses a residual "switch model?" prompt by keeping the
current model, never by switching to one. If a session is stuck on a usage
limit, wait it out (or run `resume-when-ready`) — do not spend a session-cycle
retrying with a different model.

## Usage reservation ledger recovery and rollback

The host-wide reservation ledger (`$XDG_CACHE_HOME/nogging/usage/reservations/ledger.json`)
manages shared quota headroom across repositories.

- **Malformed ledger diagnostic:** If the ledger file contains invalid JSON,
  malformed top-level entries, or broken accounting core fields (missing scope,
  non-finite/negative estimate, invalid reset timestamps, or unsafe owner filenames),
  any admission attempt halts with:
  ```text
  usage reservation ledger is malformed (<detail>); admission refused
  ```
  Admission exits non-zero before launching side effects or rewriting the file.
  Inspect `ledger.json`. Correct or remove invalid accounting entries; never
  hand-edit reservations while other sessions are actively admitting or launching.
- **Opaque reservations:** When an entry has an unrecognized version
  (`schema_version > 1`) or malformed session metadata but a valid accounting
  core, readers log:
  ```text
  warning: reservation <token>: <reason>; retained without probing
  ```
  Opaque entries are retained without executing probes or reaping them, which
  conservatively preserves headroom. If opaque entries hold quota longer than
  necessary, update the host tools to a version that understands their schema.
  Do not delete entries of live sessions.
- **Rollback to an earlier version:** Safe rollback requires rolling back only
  to a release that satisfies the **tolerant reader floor** (supporting the
  shared accounting core and tolerant decoding). Downgrading directly to
  unpatched v2.2.0 while newer sessions or version-1 entries exist is unsupported
  because v2.2.0 crashes with `KeyError: 'tmux'`. To roll back, wait for active
  sessions to complete and ensure all entries are released, or rollback to a
  patched tolerant release. Never split the ledger or delete live reservations.

## Direct test execution isolation and setup diagnostics

*Maintainers only: this applies when you run the Nogging repository's own
`scripts/**/*.test.sh` suites, which a consumer project does not have.*

Direct test scripts (`scripts/**/*.test.sh`) source `scripts/lib/test-env.sh` to
strip `NOGG_*` and `NOGGING_ROOT` from the calling environment.

- **Preventing task-done broker contamination:** In a supervised session,
  `NOGG_TASK_DONE_SOCKET` points to the active session's task broker. By clearing
  this variable before tests run, test fixtures (such as those in `nogg.test.sh`)
  are prevented from accidentally connecting to the live broker and ticking real
  tasks.
- **Named setup failures:** Direct planning setup steps (such as `plan-begin`
  fixtures in `scripts/nogg.test.sh`) report named failures (`FAIL - <scenario>: plan-begin setup failed`)
  and print captured error output rather than silently aborting or ignoring errors
  under `set -e`. Dependent assertions are skipped on setup failure, and the test
  exits non-zero.

## A half-applied worktree after a failed rebase or checkout

**Symptom.** A Lead's `git rebase`, `git merge` or `git pull` hit a read-only
`openspec/`. Files sorted before `openspec/` were already written from
upstream, but the index and `HEAD` did not move and no `rebase-merge/` or
`rebase-apply/` exists, so neither `git rebase --abort` nor a plain reset knows
about it. `git status` shows many modified files nobody edited.

**Detect.** A read-only classifier compares each dirty path with the blob at
`origin/develop`. It reports one of:

- `clean`;
- `operation-in-progress` (merge, cherry-pick, bisect, rebase; Nogg's own paused
  rebase is named as such) — not half-applied;
- `half-applied` — no operation in progress and every dirty path is
  reproducible from upstream (modified or untracked: bytes equal to
  `origin/develop:<path>`; deleted: absent at `origin/develop`);
- `mixed` — some dirty paths are reproducible, others are your own work, which
  is listed as "your work — untouched";
- `dirty` — nothing is reproducible: ordinary work in progress, never reported
  as a problem.

`./scripts/nogg doctor` prints a `NOTE` and `./scripts/nogg recover` raises
attention for `half-applied` and `mixed`. Both also report a leftover
`.nogging/state/rebase/*.json` journal at `running` with no operation in
progress, or at `paused` with no `rebase-merge/`, together with its backup ref.
The rebase refusal for a dirty tree prints the same hint. Evidence is byte
equality, not a count of modified files.

**Repair.**

```bash
./scripts/nogg worktree repair <record>          # dry run (default)
./scripts/nogg worktree repair <record> --apply
```

The dry run prints what would be restored and what is left alone. `--apply`
first snapshots the entire dirty state (tracked and untracked, via a temporary
index, leaving the working tree untouched) to
`refs/nogg/repair-backup/<branch>/<UTC-stamp>`, then restores only the proven
reproducible paths with path-scoped commands (`git restore --source=HEAD
--staged --worktree -- <paths>` and `git clean -f -- <paths>`). It never runs
`reset --hard` or a directory-wide `clean -fd`, does nothing for `dirty` and for
the non-reproducible paths of `mixed`, and refuses when an operation is in
progress or a live foreign session works there. A fenced caller gets the dry run
and hint, and a fenced `--apply` refuses `openspec/` paths and names them for
the operator. Repair does not prune a registered worktree whose directory is
gone; `git worktree prune` does.

**Rebase journals.** A journal at `running` with no git state means the engine
crashed; the backup ref `refs/nogg/rebase-backup/<branch>/<stamp>` holds the
previous tip (`git reset --hard <sha>` from an unfenced shell, deliberately).

**Pre-rebase hook limit.** `scripts/hooks/pre-rebase` (installed by
`scripts/install-hooks`) exits 1 before git writes anything when the caller is
fenced or `openspec/` is not writable and the upstream diff touches
`openspec/`; it catches `git rebase` and `git pull --rebase`. It cannot catch
`git merge` or `git pull` (git runs no hook before that checkout), and it does
not run where `core.hooksPath` diverts git away from `.git/hooks`. There the
launch-prompt rule and the detection above are the defence.

**Host recipe: a real read-only mount.** CI cannot exercise the mount. Once per
release, on the host: launch a fenced Lead (`session launch`) on a throwaway
implementation worktree, push an upstream commit that ticks a `tasks.md`
checkbox, and from the Lead's shell confirm that `git rebase origin/develop` is
refused by the hook, that `./scripts/nogg worktree rebase` succeeds through the
broker with the Lead identity kept, and that `./scripts/nogg worktree repair
<record>` on a clean tree reports `clean`.

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

*Planning sessions and maintainers only: this repairs the OpenSpec-to-Beads
mapping, and `openspec/` is writable only in a planning session.*

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
