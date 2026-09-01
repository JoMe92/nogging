# Architecture

SpecForge deliberately separates semantic decisions from mechanical state
reconciliation. It is not a general-purpose ALM system.

## Data contracts

Every OpenSpec task has one immutable identifier (`TASK-<AREA>-<NNN>`). Every
materialized Bead is created with exactly two labels:

```text
openspec:change:<change-id>
openspec:task:<task-id>
```

Labels are used because Beads does not provide arbitrary per-issue custom
fields. An execution agent adds a note before closing a Bead containing a Git
commit SHA and validation evidence. A material discovery is recorded on the
active Bead with the native `discovery` label plus a required human-readable
note (`bd update <id> --add-label discovery --append-notes "..."`); a blocking
discovery additionally sets the Bead status to `blocked`. The mechanical sync
finds pending discoveries by the `discovery` label alone and never parses the
note. It reads the full Bead status set, not the non-closed default, so a
discovery closed before a planning session reviews it still surfaces. A
planning session records a review with `scripts/specforge discoveries --ack
<id>...`; the acknowledgement ledger
(`.specforge/state/acknowledged-discoveries.json`) then hides that Bead, open or
closed. The ledger is local, additive, and safe to delete — a deleted ledger
just re-surfaces every discovery once.

Materialization is idempotent: rerunning it creates only missing mapped Beads
and never duplicates work. Its "already mapped" check reads closed Beads too
(the same full-status read the sync pass uses), so re-running `materialize` for
a change whose tasks are partly done does not duplicate the Beads of the
finished tasks. The planner creates dependencies deliberately with
`bd dep add <child> <blocking-parent>` after materialization; this keeps their
meaning explicit rather than guessing from Markdown order.

## State and safety

Changes are `open`, `done`, or `archived`. `done` requires every mapped Bead to
be closed. `archived` is an explicit Product Owner operation. The sync process
does not archive, push, close Beads, create requirements, or interpret a
discovery.

### Closed-Bead reconciliation

The sync pass enumerates every mapped Bead whose status is `closed`, alongside
the non-closed ones, and mirrors each closed Bead to its task checkbox and the
change's `execution-log.md`. `bd list` scopes to non-closed issues by default,
so `scripts/specforge` asks for the full status set explicitly; without this a
closed mapped Bead — the exact thing that should be mirrored — was never seen.

Each execution-log entry carries closure evidence, since an execution agent can
never write the spec itself: the Bead ID and mapped task, the closure timestamp
(`closed_at`, falling back to `updated_at`), the implementation commits found by
scanning `git log` subjects for the enforced `[<bead-id>]` token and by reading
SHAs out of the Bead note (or an explicit "none found"), and the Bead's
human-readable note preserved verbatim as an indented block. Entries stay
idempotent across re-runs through a stable `<!-- specforge:<id>:<closed_at> -->`
event key; a later note amendment moves the timestamp and appends a fresh entry
rather than rewriting history.

### Sync failure handling

`scripts/specforge` takes a short exclusive file lock for each sync. Planning
takes a separate lock. A stale lock has a PID, host, timestamp and TTL, so it
can be inspected and removed deliberately with `plan-end --force` after a
crash.

A failed sync writes `.specforge/state/sync-failure.json`: a `classification`
(`transient` or `permanent`), the error, the consecutive-failure `attempts`
count, `max_attempts`, `first_seen` / `last_seen`, and `next_retry_after`.
Classification is mechanical, by exception type — a failed invariant audit,
mapping conflict or missing task is `permanent` and is not retried
automatically; lock contention and `git` / `bd` / JSON errors are `transient`
and retry with capped exponential backoff until `max_attempts`. Every failure
is also appended to `.specforge/state/sync-failures.jsonl`. A successful sync
deletes the active record (the JSONL history is kept). The caller (the timer)
consults `classification` and `next_retry_after` before re-invoking; `sync`
itself stays single-shot and never sleeps or loops. Retry is safe because
execution-log entries have stable event keys.

The sync process sets its own narrowly scoped `SPECFORGE_WRITER=sync` commit
environment, allowing the repository hook to accept only its execution mirror.

If a planner removes a task whose Bead is active, audit fails closed. The Bead
is retained and reported as orphaned; nothing is deleted or silently closed.

## Session supervision

Claude Code sessions that SpecForge starts for Lead Agent or specialist work
are supervised, not ephemeral foreground processes. `scripts/specforge session`
is a mechanical layer over tmux: it starts and tracks processes and makes no
product decision.

- **Substrate.** A dedicated tmux server socket (`tmux -L specforge`,
  `session_tmux_socket`) isolates managed sessions from the operator's own
  tmux and makes them enumerable. The server and the Claude process run as the
  same non-privileged user; no `sudo`.
- **Naming.** `sf-<role>-<bead>-<nonce>`. Before creating a session SpecForge
  checks the metadata store, any leftover log, and `tmux has-session`; on a
  collision it regenerates the nonce and then fails rather than reusing or
  overwriting an existing session.
- **Durable metadata.** One JSON record per session under
  `.specforge/state/sessions/<name>.json`: `name`, `bead_id`, `role`, `host`,
  `started_at`, `working_dir`, redacted `command`, `owner`, `state` (one of
  `starting`, `running`, `idle`, `stopped`, `failed`, `retired`), `log_path`,
  and `ended_at`/`exit_reason` on a terminal state. Written before the Claude
  process is exec'd and updated on every transition. The store is local state
  (gitignored, like the rest of `.specforge/state/`) and safe to delete — a
  deleted record only drops history for an already-finished session.
- **Liveness.** `session list` cross-checks each record against `tmux
  list-sessions`; a record still in an active state whose tmux session is gone
  is reported as `failed`, never trusted as `running`. `list` is read-only and
  runs in a bare SSH shell.
- **Append-only log.** `tmux pipe-pane -o` streams pane output through
  `scripts/session-log-writer` to `<name>.log`, size-rotated to
  `session_log_rotation_depth` at `session_log_max_bytes` (size-based only,
  matching the sync failure log). Readable with `cat`/`tail`/`less` — no attach.
- **Least authority.** Claude starts via `scripts/session-launch` with
  `.specforge/session-launch-profile.json`: no `git push`, no remote Dolt
  sync, no destructive shell, no extra directories. The wrapper sets no shell
  trace and takes no token as an argument; the recorded `command` and the log
  are run through a redactor that removes the values of secret-bearing
  environment variables.
- **No autonomous claiming.** `session launch` issues no `bd` mutation (its
  only `bd` call is a read-only `bd show` to confirm the Bead exists). The
  appended system prompt (`.specforge/session-launch-prompt.md`) states that
  claiming or starting a Bead is a deliberate operator-directed action.
- **Deliberate lifecycle.** `attach`, `stop`, `cleanup` are explicit
  subcommands; none happens as a side effect of another. `cleanup` refuses a
  record in `starting`/`running`/`idle`.

### Session supervision vs. Task-tool specialists

The Lead Agent's own session runs supervised (`sf-lead-<bead>-<nonce>`). When
it delegates to a specialist through the Task tool, that call runs **in
process** inside the Lead Agent's session — no separate tmux session or record,
visible in the Lead session's log, under the Lead session's profile. A
specialist is given **its own** supervised tmux session
(`sf-specialist:<type>...`) only when the work needs to run as a separate
long-lived Claude Code process the operator wants to observe or stop
independently; it still obeys every specialist boundary rule.

## The OpenSpec write boundary

Invariant 5 — execution agents do not alter `openspec/` — is enforced in depth
by three layers. Each is independent, and each covers a way past the others.

**1. `PreToolUse` guard (tool level, Claude Code only).**
`scripts/hooks/pre-tool-use-openspec-guard`, wired into `.claude/settings.json`
with matcher `Edit|Write`. Claude Code sends the tool call as JSON on stdin; the
guard reads `.tool_input.file_path` (mechanism verified against Claude Code
2.1.237), resolves it under `CLAUDE_PROJECT_DIR`, and if it lands in `openspec/`
while `.specforge/locks/planning.lock` is absent, writes an explanation to
stderr and exits `2` to block the call. Lock present, or path outside
`openspec/`: the call proceeds. The lock is held only for the duration of a
planning session (`scripts/specforge plan-begin` … `plan-end`). This layer
stops prompt drift and accidental edits inside a Claude Code session. It does
nothing for other editors or agents, for `Bash` writes (`sed -i`, redirection,
`git apply`), or when `jq` is missing, and it only tests whether the lock file
exists, not its owner or freshness.

**2. `pre-commit` (result invariant, Git).**
`scripts/hooks/pre-commit` rejects a commit (exit `1`) whose staged paths match
`^openspec/` unless `SPECFORGE_WRITER` is `planning` or `sync` — the two writers
the boundary already trusts. This catches `openspec/` edits that bypassed
layer 1. It is path-based, not content-based; it is local only, not run in CI;
and `git commit --no-verify` skips it.

**3. `commit-msg` (result invariant, Git).**
`scripts/hooks/commit-msg` checks the subject line: Conventional Commit shape
(every commit, planning and sync included), and — unless `SPECFORGE_WRITER` is
`planning` or `sync` — a real Beads issue-ID token
(`\[[A-Z][A-Z0-9]*-[0-9a-z]+\]`, e.g. `[SPEC-7ec]`; a bare `[]` or `[BEAD-XXX]`
fails). The rejection names the rule and the exemption. This is proof at the
result: execution work that touched `openspec/` cannot land without either a
Beads ID that ties it to claimed work or the `SPECFORGE_WRITER` exemption the
boundary governs. The token is checked for shape only — the hook does not
confirm the ID exists or is claimed — and only the subject line counts.
`scripts/hooks/commit-msg.test.sh` (run by `scripts/test` and CI) covers the ID
and exemption cases; `pre-commit` and the `PreToolUse` guard have no equivalent
test.

Layers 2 and 3 are installed into the active hooks directory by
`scripts/install-hooks`.

### Interaction

| Layer | Runs | Blocks | Left for the next layer or review |
| --- | --- | --- | --- |
| `PreToolUse` guard | before the edit | `Edit`/`Write` into `openspec/` with no planning lock | Bash writes and non–Claude-Code edits, caught when committed |
| `pre-commit` | before the commit | staged `openspec/` paths from an execution writer | `--no-verify` or an uninstalled hook: the commit lands Bead-less and visible to review |
| `commit-msg` | before the commit | an execution commit naming no real Beads ID | `--no-verify`: a reviewer sees a Bead-less `openspec/` commit and rejects it |

No single accidental action defeats the boundary. A deliberate bypass
(`--no-verify` plus a hand-written Bead-less commit) is left to human review —
the same place requirement-to-code fidelity already lives.

### Limitations

- **Delivery.** The two Git hooks run only where `scripts/install-hooks` has put
  them *and* Git actually reads them. When `core.hooksPath` is set — as the
  Beads integration does, pointing it at `.beads/hooks` — Git ignores
  `.git/hooks/` and neither SpecForge hook runs (observed 2026-08-31).
  Reconciling the two hook paths is tracked as a discovery on SPEC-7ec.
- **Not server-side.** Nothing runs in CI, so a locally bypassed commit can
  still be pushed; review is the backstop.
- **Scope.** The layers govern *who* may write `openspec/` and *that* execution
  work is tracked. They do not judge whether an `openspec/` change is correct or
  agreed; tests, review, and Product Owner acceptance remain that evidence.
- **Tool coverage.** The `PreToolUse` guard is Claude Code-specific and
  `Edit`/`Write` only; the two Git hooks are the portable floor.

## Invariants

1. Task IDs are unique.
2. Every mapped Bead points to one existing task.
3. A task is checked only when its mapped Bead is closed.
4. A change cannot be done while a mapped Bead is not closed.
5. Execution agents do not alter `openspec/`.

Invariant 5 is enforced in depth by three layers (see *The OpenSpec write
boundary*). Requirement-to-code fidelity is not claimed to be automatically
decidable; tests, review and Product Owner acceptance remain the evidence for
that judgement.
