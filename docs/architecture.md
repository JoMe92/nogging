# Architecture

Agentsembli SpecForge deliberately separates semantic decisions from mechanical state
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
planning session records a review with `scripts/nogg discoveries --ack
<id>...`; the acknowledgement ledger
(`.nogging/state/acknowledged-discoveries.json`) then hides that Bead, open or
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
so `scripts/nogg` asks for the full status set explicitly; without this a
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

### Safe-state gate

Before it takes the sync lock, `sync` classifies the repository with
`repo_sync_state()` and **skips the tick** — no mirroring, no commit — when the
working tree is not a safe place to write:

- a fresh `planning.lock` is held (planning and sync must not interleave);
- a merge, rebase, cherry-pick, or bisect is in progress (`.git/MERGE_HEAD`,
  `rebase-merge/`, `rebase-apply/`, `CHERRY_PICK_HEAD`, `BISECT_LOG`, with the
  git directory found via `git rev-parse --git-dir` so linked worktrees work);
- `HEAD` is detached;
- `HEAD` is on a branch in `sync_protected_branches` (default `["main",
  "develop"]`).

A skip is a **no-op, not a failure**: it prints `sync: skipped (<reason>)`,
exits 0, writes no `sync-failure.json`, applies no backoff, and leaves
`last-success.json` untouched, so the next tick simply retries once the reason
clears. This is weakness **W5** from the crash-resilience handoff — the timer
firing every 30 s used to drop a `chore(sync)` commit onto whatever branch
`HEAD` pointed at, including mid-`git switch` during an integration.

`sync --now` (operator-invoked, `/sync-now`) passes `on_request=True`, which
**allows a protected branch** — a deliberate catch-up after working directly on
`develop` — but still refuses a genuine mid-merge/rebase/cherry-pick/bisect or a
held planning lock, telling the operator to finish that first.

A successful sync records the branch it committed on in `last-success.json`
(`{"at", "branch"}`; a legacy `at`-only file still reads) and prints
`sync: note — mirroring on <new> (last run was on <old>)` when it changes. A
skipped tick writes `.nogging/state/last-skip.json` (`{"at", "reason"}`,
cleared by the next real or no-op sync); `doctor` surfaces it as
`NOTE  last sync skipped: <reason> (<age>)` so a stalled mirror is visible.

### Sync failure handling

`scripts/nogg` takes a short exclusive file lock for each sync. Planning
takes a separate lock. A stale lock has a PID, host, timestamp and TTL, so it
can be inspected and removed deliberately with `plan-end --force` after a
crash.

A failed sync writes `.nogging/state/sync-failure.json`: a `classification`
(`transient` or `permanent`), the error, the consecutive-failure `attempts`
count, `max_attempts`, `first_seen` / `last_seen`, and `next_retry_after`.
Classification is mechanical, by exception type — a failed invariant audit,
mapping conflict or missing task is `permanent` and is not retried
automatically; lock contention and `git` / `bd` / JSON errors are `transient`
and retry with capped exponential backoff until `max_attempts`. Every failure
is also appended to `.nogging/state/sync-failures.jsonl`. A successful sync
deletes the active record (the JSONL history is kept). The caller (the timer)
consults `classification` and `next_retry_after` before re-invoking; `sync`
itself stays single-shot and never sleeps or loops. Retry is safe because
execution-log entries have stable event keys.

The sync process sets its own narrowly scoped `NOGGING_WRITER=sync` commit
environment, allowing the repository hook to accept only its execution mirror.

If a planner removes a task whose Bead is active, audit fails closed. The Bead
is retained and reported as orphaned; nothing is deleted or silently closed.

## Session supervision

Claude Code sessions that SpecForge starts for Lead Agent or specialist work
are supervised, not ephemeral foreground processes. `scripts/nogg session`
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
  `.nogging/state/sessions/<name>.json`: `name`, `bead_id`, `role`, `host`,
  `started_at`, `working_dir`, redacted `command`, `owner`, `state` (one of
  `starting`, `running`, `idle`, `stopped`, `failed`, `retired`), `log_path`,
  and `ended_at`/`exit_reason` on a terminal state. Written before the Claude
  process is exec'd and updated on every transition. The store is local state
  (gitignored, like the rest of `.nogging/state/`) and safe to delete — a
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
  `.nogging/session-launch-profile.json`: no `git push`, no remote Dolt
  sync, no destructive shell, no extra directories. The wrapper sets no shell
  trace and takes no token as an argument; the recorded `command` and the log
  are run through a redactor that removes the values of secret-bearing
  environment variables.
- **No autonomous claiming.** `session launch` issues no `bd` mutation (its
  only `bd` call is a read-only `bd show` to confirm the Bead exists). The
  appended system prompt (`.nogging/session-launch-prompt.md`) states that
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

### The Orchestration Agent and the command floor

The **Orchestration Agent** is a fourth supervised session persona, above
Planning and the Lead Agent (see `docs/operating-model.md`). Mechanically it is
an ordinary supervised session — a durable record, an append-only log, listed by
`session list` — with three differences:

- **No Bead.** `--role orchestrator` is launched without `--bead`; the record
  carries `bead_id: null` and `floor_lifted: true`. The session name is the
  fixed singleton `nogg-orchestrator-<slug>` (no nonce); `orchestrator run`
  adopts an existing live one rather than failing on the name.
- **The command floor is lifted — for this role only.** The `orchestrator`
  profile (`bypassPermissions`, empty deny, `specforge_floor: false`,
  `specforge_openspec_readonly: false`) is the *single* documented exception to
  "a fixed command floor cannot be lifted by any profile". `session launch`
  reads those two keys **only** when the role is `orchestrator`; for every other
  role they are ignored and the floor is unioned in and `openspec/` fenced
  exactly as before, so pointing a `lead` session at `--profile orchestrator`
  still runs it floored. This is not an OS sandbox escape — a `trusted` session
  can already push and merge. It is a role that was never meant to be fenced,
  and the safeguards for it are **visibility** (`session list` /  `doctor` show
  it as `FULL-ACCESS`, the append-only log, the durable record) and the
  **single-instance lock** (`.nogging/locks/orchestrator.lock`), not a
  boundary. The accepted residual risk is that an always-on god-mode session
  that auto-resumes its own conversation is a standing prompt-injection target;
  it is mitigated by delivery-host-only blast radius, full visibility, and the
  single instance, not eliminated.
- **Always-on.** A rendered systemd user service
  (`nogg-orchestrator-<slug>.service`, `Restart=always`,
  `WantedBy=default.target`) runs `scripts/nogg orchestrator run`, an
  idempotent supervisor that keeps the one session alive and resumes its
  conversation with `claude --continue` after a crash or a reboot (with
  `loginctl enable-linger`). The session registers with Remote Control for
  phone access. `doctor` reports the service state and linger without failing
  on its absence — it is opt-in.

## The OpenSpec write boundary

Invariant 5 — execution agents do not alter `openspec/` — is enforced in depth
by three layers plus a CI backstop. Each is independent, and each covers a way
past the others. Layer 1 is tool-agnostic; layers 2–3 are Git hooks.

**1. The pre-edit boundary (filesystem + per-session sandbox).**
Outside a planning session, `openspec/changes/` and `openspec/specs/` are closed
to an execution agent of any tool. Three parts:

- **The sentinel.** `scripts/nogg plan-end` writes
  `.nogging/locks/openspec.readonly` (`{closed_at, by}`); `plan-begin` removes
  it. A fresh install starts with it present (`scripts/install-hooks`, or the
  first `doctor` run where `core.hooksPath` made the installer skip that step).
  It is local state under `.nogging/locks/` (gitignored) and advisory to the
  guards below — not a file-mode change, so `git switch` / `merge` / `checkout`
  and the `sync` writer are unaffected by it.
- **The per-session read-only root.** `scripts/nogg session launch` for a
  non-planning role, when no fresh planning lock is held, adds `openspec/` to
  the session's effective authority as read-only. A Claude session gets
  `Edit`/`Write`/`MultiEdit` `deny` rules for `openspec/**` in its per-session
  effective-settings file (unioned in before the file is written, like the
  command floor). A Codex session gets `openspec/` as a read-only sandbox root
  (`--sandbox-state-readable-root` where the installed `codex` exposes it on a
  plain launch, otherwise the `.codex/rules/` execpolicy deny that
  `codex-onboarding` ships). A planning-role session, or one launched while a
  fresh planning lock is held, keeps `openspec/` writable.
- **The `PreToolUse` guard (Claude Code fast path).**
  `scripts/hooks/pre-tool-use-openspec-guard`, wired into `.claude/settings.json`
  with matcher `Edit|Write`. It reads `.tool_input.file_path` (mechanism
  verified against Claude Code 2.1.237), resolves it under `CLAUDE_PROJECT_DIR`,
  and exits `2` to block the call when the path is under `openspec/` and the
  sentinel is present, or `.nogging/locks/planning.lock` is absent, or that
  lock's `created_at` is older than `planning_lock_ttl_seconds` — the same
  staleness rule `lock()` applies (closes crash-resilience weakness W6, an
  asymmetric hole where a stale lock blocked `plan-begin` yet still permitted
  edits). It is the fast in-model signal a Claude session sees before the
  sandbox would surface an `EACCES`; it does nothing for other tools, for `Bash`
  writes (`sed -i`, redirection, `git apply`), or when `jq` is missing.

`scripts/nogg doctor` reports the boundary: `openspec write boundary: OPEN
(planning session active, lock age Ns)` / `LOCKED` / `LOCKED (stale planning
lock present — run plan-end --force)`.

**2. `pre-commit` (result invariant, Git).**
`scripts/hooks/pre-commit` rejects a commit (exit `1`) whose staged paths match
`^openspec/` unless `NOGGING_WRITER` is `planning` or `sync` — the two writers
the boundary already trusts. This catches `openspec/` edits that bypassed
layer 1. It is path-based, not content-based; it is local only, not run in CI;
and `git commit --no-verify` skips it.

**3. `commit-msg` (result invariant, Git).**
`scripts/hooks/commit-msg` checks the subject line: Conventional Commit shape
(every commit, planning and sync included), and — unless the commit is a writer
commit — a real Beads issue-ID token
(`\[[A-Z][A-Z0-9]*-[0-9a-z]+\]`, e.g. `[SPEC-7ec]`; a bare `[]` or `[BEAD-XXX]`
fails). A commit is a writer commit when `NOGGING_WRITER` is `planning` or
`sync` **or** its message body carries a `Nogging-Writer: planning` /
`Nogging-Writer: sync` trailer. The two forms are exact parity: the
environment variable is convenient locally, the trailer travels inside the
commit object so CI applies the identical rule from the pushed history alone. A
writer commit still needs a Conventional subject. The rejection names the rule
and both exemption forms. This is proof at the result: execution work that
touched `openspec/` cannot land without either a Beads ID that ties it to
claimed work or the writer exemption the boundary governs. The token is checked
for shape only — the hook does not confirm the ID exists or is claimed — and
only the subject line counts. `scripts/hooks/commit-msg.test.sh` (run by
`scripts/test` and CI) covers the ID, the env exemption and the trailer
exemption; `scripts/agents-boundary.test.sh` covers the `PreToolUse` guard
(openspec/ block, the sentinel, a stale planning lock, a path outside
`openspec/`); `pre-commit` has no equivalent test.

`scripts/nogg`'s deterministic sync commit sets both: the
`NOGGING_WRITER=sync` environment and a `Nogging-Writer: sync` trailer.
Planning commits use a Conventional `docs(openspec):` / `chore(openspec):`
subject plus a `Nogging-Writer: planning` trailer; the non-Conventional
`plan:` subject prefix is retired.

Layers 2 and 3, together with the `pre-push` branch-name check, are installed
into the active hooks directory by `scripts/install-hooks`. Where
`core.hooksPath` diverts Git away from that directory the CI `invariants` job
(below) is the enforced backstop.

### Interaction

| Layer | Runs | Blocks | Left for the next layer or review |
| --- | --- | --- | --- |
| Pre-edit boundary — sentinel + per-session read-only root | before the edit, tool-agnostically (Claude *and* Codex) | a launched execution session of any tool persisting a change under `openspec/changes/` or `openspec/specs/` outside a planning session | an edit by a process outside a launched session (a plain editor, `sed -i` in a bare shell), caught when committed |
| `PreToolUse` guard | before the edit, Claude Code only | the same as a fast in-model signal, and a stale planning lock (W6) | Bash writes, non–Claude-Code edits, a missing `jq` |
| `pre-commit` | before the commit | staged `openspec/` paths from an execution writer | `--no-verify` or an uninstalled hook: the commit lands Bead-less and visible to review |
| `commit-msg` | before the commit | an execution commit naming no real Beads ID | `--no-verify`: caught by the CI `invariants` job, then review |
| CI `invariants` job | on every pull request | a non-conforming head branch, or any introduced non-merge commit that fails the `commit-msg` rule | a branch pushed with no PR yet; a deliberate history rewrite before review |

No single accidental action defeats the boundary. A deliberate bypass
(`--no-verify` plus a hand-written Bead-less commit) is caught by the CI
`invariants` job on the pull request, and past that by human review — the same
place requirement-to-code fidelity already lives.

### CI backstop: the `invariants` job

Because `core.hooksPath` points Git at `.beads/hooks` in this repository (and
may in a fresh install once Beads diverts it), `.git/hooks/commit-msg` and
`.git/hooks/pre-push` do not run here. The `invariants` job in
`.github/workflows/specforge-validate.yml` is the enforced backstop: on every
`pull_request` it runs `scripts/check-branch-name` against the head branch and
re-runs `scripts/hooks/commit-msg` over every non-merge commit the PR
introduces (`git rev-list --no-merges origin/<base>..HEAD`, each
`git show -s --format=%B` piped to the hook). It reuses the two rule scripts
rather than re-encoding them, and the `Nogging-Writer:` trailer is what makes
the writer exemption reproducible server-side. A violation fails the PR naming
the branch, or the commit by SHA and subject.

### Limitations

- **Delivery.** The Git hooks run only where `scripts/install-hooks` has put
  them *and* Git actually reads them. When `core.hooksPath` is set — as the
  Beads integration does, pointing it at `.beads/hooks` — Git ignores
  `.git/hooks/` and no SpecForge hook runs (observed 2026-08-31). The CI
  `invariants` job is the authoritative backstop for branch and commit
  discipline in that case. Reconciling the two hook paths is tracked as a
  discovery on SPEC-7ec.
- **Server-side, PR-only.** The `invariants` job runs on `pull_request`, so a
  branch pushed without an open PR is unchecked until one opens, and a commit
  made locally with only `NOGGING_WRITER` set and no trailer passes locally
  but fails CI. `pre-commit` still runs nowhere in CI; review remains its
  backstop.
- **Scope.** The layers govern *who* may write `openspec/` and *that* execution
  work is tracked. They do not judge whether an `openspec/` change is correct or
  agreed; tests, review, and Product Owner acceptance remain that evidence.
- **Tool coverage.** The pre-edit boundary is tool-agnostic: the sentinel and
  the per-session read-only root apply to Claude and Codex alike. The
  `PreToolUse` guard on top is Claude Code-specific and `Edit`/`Write` only; the
  two Git hooks are the portable floor. A Codex read-only sandbox root depends
  on the installed `codex` build — where it is unavailable the `.codex/rules/`
  execpolicy deny (`codex-onboarding`) plus `pre-commit` carry it.

## Invariants

1. Task IDs are unique.
2. Every mapped Bead points to one existing task.
3. A task is checked only when its mapped Bead is closed.
4. A change cannot be done while a mapped Bead is not closed.
5. Execution agents do not alter `openspec/`.

Invariant 5 is enforced in depth by three layers (see *The OpenSpec write
boundary*). Requirement-to-code fidelity is not claimed to be automatically
decidable; tests, review and Product Owner acceptance remain the evidence for
that judgement. The **Orchestration Agent** under an explicit `takeover plan`
instruction is the one persona that writes `openspec/` outside a `/plan`
session; its commit still carries the `Nogging-Writer: planning` trailer, so
the CI `invariants` job accepts it exactly as it accepts a planning session's
commit (see *The Orchestration Agent and the command floor*).
