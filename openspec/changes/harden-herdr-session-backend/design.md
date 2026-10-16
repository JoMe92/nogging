## Context

The baseline is `develop` at 7702eaf plus the planning commit that archived
`add-herdr-session-backend` into `openspec/specs/session-backends/`. The real
Pi acceptance of that change, `docs/acceptance/2026-10-16-herdr-backend.md`,
ended **Overall: fail**. Its discoveries D1–D10 are recorded on `SPEC-emer`.
The Orchestration Agent added one more defect: an orchestrator lock that reads
as stale while its holder lives. The spike facts in
`scripts/fixtures/herdr/spike/FACTS.md` still hold for herdr 0.9.5.

Code as it stands at the baseline:

- **D6.** `session_cleanup()` in `scripts/nogg` ends with: if no non-retired
  record is left *in this checkout* and the shared tmux server lists any
  session, call `idle_shutdown()`, which runs `tmux kill-server`. Records are
  kept per checkout, but `tmux -L nogging` is shared with the Orchestration
  Agent and with every other checkout. So a cleanup in a quiet worktree kills
  them all.
- **Orchestrator lock.** `acquire_orchestrator_lock()` writes `{pid, host,
  created_at}`. `recover` marks the lock STALE once `created_at` is older than
  `orchestrator_lock_ttl_seconds` (86400), however alive the holder is. The
  supervisor rewrites `created_at` only when it restarts. `recover` also
  probes the PID with `pid_alive()` in the caller's own PID namespace. A
  sandboxed Lead cannot see host PIDs, so it reports the holder as dead.
  Autonomous Leads run `recover` first and stop on any stale lock.
- **D10.** `scripts/openspec-sandbox` (`supervise`) loads `scripts/nogg` with
  `NOGGING_ROOT` set to the *launch* cwd. Its broker accepts exactly
  `{"bead_id"}` and ticks that launch checkout. The Lead's implementation
  worktree, created later, is never ticked.
- **D9.** `HerdrBackend._ensure_server()` spawns `herdr --session <ns> server`
  in the caller's PID namespace and writes `server.json` as `{pid, start}`.
  `start()` reads the pane's root PID from herdr and then reads
  `/proc/<pid>/stat` locally. A Lead runs inside the `openspec-sandbox` PID
  namespace (`unshare --pid --fork --kill-child=KILL --mount-proc`). When it
  starts the server, the server lives in that namespace, its PIDs mean nothing
  on the host, and the server dies with the Lead.
- **D2.** When the dedicated server is down, `herdr status` reports `not
  running`. The backend still returns those records as *unknown*, and unknown
  counts as live for the same-Bead launch check.
- **D1.** `HerdrBackend.orphans()` treats every `sf-` pane in the shared
  workspace as an orphan unless this checkout's active records own it.
- **D8.** `prepare()` runs `workspace create`. That opens an unlabelled root
  `$SHELL` pane, and nothing ever closes it.
- **D3.** `scripts/session-log-writer` is a bash `read -r` loop. Full-screen
  TUIs emit almost no LF, so the log freezes, the line buffer grows without
  limit, and the size bound is broken (a 3,066,138 B `.log.1` was observed).
  `_archive_log()` archives only the active file.
- **D4.** Codex `nudge --message` types the text into the pane. Verification
  uses only the `Pasted Content` signal, so short typed text reads as
  delivered. `session send` is correct because it uses `codex queue`.
- **D5.** For Antigravity, `_pane_input_pending()` falls back to "is the last
  non-blank line non-empty". Antigravity's permanent status bar makes that
  check always true.
- **D7.** `session launch --resume` refuses Codex. The spike verified that
  `codex resume <id>` works natively.

## Goals / Non-Goals

**Goals:**

- Remove the two herdr-independent hazards (D6, orchestrator lock) and the
  misdirected tick (D10). These form their own lane, which starts immediately.
- Make herdr safe in the real topology: several checkouts, sandboxed Leads,
  and a server that can be down.
- Make logs live and bounded on both backends, and nudge/send verification
  truthful for every gated runtime.
- Support Codex exact resume.
- Re-run the real Pi acceptance.

**Non-Goals:** see `proposal.md`.

## Decisions

### 1. Test discipline for GitHub runners (every task)

Three PRs of the previous change failed in CI on these points, so every new
or changed suite SHALL follow these rules:

- **No Dolt and no real `bd`.** Stub `bd` through `beads_command` or a `PATH`
  stub, as the existing suites do.
- **No PID-range assumptions.** Never hard-code a "dead" PID: `pid_max` can be
  4194304. To get a dead PID, start a child and reap it. To get a live one,
  keep a child running. Treat PID-namespace identities as opaque strings, and
  inject a foreign namespace by writing a different string.
- **User namespaces may be missing.** Never call `unshare` and never run
  `openspec-sandbox` `supervise` in a test. Simulate a fenced caller with
  `NOGG_OPENSPEC_FENCED=1` plus injected namespace strings. Test the broker
  through a directly callable request handler.
- **Socket paths stay under 108 bytes.** Create every test socket under a
  short directory (`mktemp -d /tmp/nogg.XXXXXX`), never under `$TMPDIR` or the
  repository path, and assert the length.
- **Clean environment.** Unset inherited `NOGG_*`, `HERDR_*` and `TMUX`.
- **One suite per task.** Each task adds its own suite under
  `scripts/<name>.test.sh`, so parallel tasks do not edit the same test file.
  Existing suites change only where they asserted the fixed defect.

### 2. Cleanup never kills a shared tmux server that hosts sessions (D6, TASK-HHB-001)

`session cleanup` SHALL call the tmux backend's `idle_shutdown()` only when
the dedicated server's own `list-sessions` succeeds *and* reports no session.
A failed listing counts as "not empty". Whether the current checkout's records
are retired no longer matters. With tmux's default `exit-empty on`, a server
already exits after its last session, so in practice cleanup no longer kills
it. The guard remains for a server configured with `exit-empty off`. The
"server stopped" message is printed only when a stop actually happened.
`TmuxBackend.idle_shutdown()` stays the only `kill-server` call site.

The suite uses the tmux `PATH` stub. It covers: a foreign `nogg-orchestrator-*`
session plus all local records retired, which must log no `kill-server`; an
empty server; and a failed listing.

### 3. Orchestrator lock staleness is bound to the holder's liveness (TASK-HHB-002)

`acquire_orchestrator_lock()` SHALL write `{pid, host, created_at, pid_start,
pid_ns}`, in the same shape as the planning lock's ownership fields. One shared
classifier SHALL decide the lock's state for `orchestrator run`, `orchestrator
status`, `recover` and `doctor`:

| Holder as seen by the caller | State | Stale? |
| --- | --- | --- |
| Same host and same PID namespace; PID alive with a matching start time | held, verified | never, at any age |
| Same host and same namespace; PID gone or start time different | dead | yes; reclaimable without `--force` |
| Legacy lock (no `pid_start`); PID alive and its command line is a `nogg … orchestrator run` | held, verified | never |
| Legacy lock; PID alive but running another command | dead (PID reused) | yes |
| Same host, but a different or unobservable PID namespace, or the caller is fenced (`NOGG_OPENSPEC_FENCED=1`) | held, unverifiable | never |
| Another host | held, unverifiable | only when older than `orchestrator_lock_ttl_seconds` |

So `orchestrator_lock_ttl_seconds` only covers the case where the holder runs
on another host. `recover` adds an attention item, and exits non-zero, only
for a stale state. An unverifiable holder is printed as such, without an
attention item. The legacy row matters because the always-on supervisor
(currently PID 926) keeps the lock it wrote with the old code until it
restarts.

Rejected: refreshing `created_at` with a heartbeat. It adds a writer loop, and
it still cannot verify a holder from inside the sandbox.

### 4. The task-done broker ticks the requesting checkout (D10, TASK-HHB-003)

- **Client.** `task_done()` with `NOGG_TASK_DONE_SOCKET` sends
  `{"bead_id": <id>, "checkout": <absolute root of the calling checkout>}`.
- **Broker.** The broker in `scripts/openspec-sandbox` accepts exactly these
  two keys. It resolves the repository's registered worktrees *at request
  time*, from Git worktree metadata as `canonical_repository_state()` does,
  because a Lead's implementation worktree is usually created after launch. It
  ticks only when `checkout` resolves exactly to one of those roots, and it
  runs the existing closed-Bead tick against that checkout's live `tasks.md`.
  It still accepts no shell command, replacement text or other path.
- **Refusals.** A request without `checkout`, with an unregistered path, or
  with a path from another repository is refused with a message that names
  the problem. A refusal never falls back to the launch checkout.
- **Mixed versions.** A broker that predates this change rejects the new key.
  The client then reports that the session must be relaunched; it does not
  retry without `checkout`.
- **Contract.** `openspec-sandbox --contract` adds the feature
  `checkout-task-broker`, and launch preflight requires it, so every newly
  launched session gets the new broker.
- **Testability.** The request handling is factored into a directly callable
  function, so the suite runs without user namespaces. The suite uses a
  temporary repository with one linked worktree and a stubbed `bd` that
  returns a closed, mapped Bead.

### 5. The herdr server runs in the host namespace; identities work from any namespace (D9, TASK-HHB-004)

**Start only outside the sandbox.** `_ensure_server()` SHALL NOT spawn a
server when `NOGG_OPENSPEC_FENCED=1`, the marker that `openspec-sandbox` sets
for every runtime it wraps. Such a caller, finding the server down, is refused
before any record, workspace or pane is created. The refusal points to `scripts/nogg session
herdr-server start` (Decision 6) or to a launch from an unsandboxed shell (the
operator or the Orchestration Agent).

Rejected: a host-side broker op that starts the server for a sandboxed Lead. It
would widen the broker's single, narrow purpose and couple this task to
TASK-HHB-003's file. Sandboxing is not the Product Owner's goal; having no
outside reach is.

**Receipt.** `server.json` SHALL hold `{pid, start, pid_ns, socket: {dev, ino,
ctime_ns}}`. `pid_ns` is the server's PID namespace as seen by the host-side
starter. The socket identity is taken from `lstat` once the socket exists and
passes the existing ownership and mode check. A server restarted by anyone
binds a new socket, so the socket identity changes.

**Ownership of a running server.** These checks apply to every caller:

- the config file is byte-equal to Nogging's config;
- the socket check passes;
- the socket identity equals the receipt.

A caller that shares `pid_ns` must also find `pid` alive with a matching
`start`. A legacy receipt without `pid_ns` or socket identity is verified only
by a host-side caller, the old way. `session herdr-server start` upgrades it
in place. A fenced caller treats a legacy receipt as unverifiable and is
refused with the pointer above.

**Pane identity.** `start()` SHALL record the pane's `terminal_id` (reported
by herdr `pane list`) in `backend_ref`, together with:

- `session_pid`: herdr's `shell_pid`;
- `session_pid_ns`: the server's namespace, taken from the receipt, not read
  from `/proc/<pid>` by the caller;
- `session_pid_start`: recorded only when the caller shares that namespace,
  otherwise null.

**Liveness.** A record is alive when its pane resolves (by ID, else by unique
label) and herdr reports the recorded `terminal_id` and `shell_pid` for it.
When the caller shares the namespace and a start time is recorded, the start
time must also match. A pane exits together with its root process, and a
restart issues a new `terminal_id` (spike fact c), so this check is exact from
any namespace. A legacy record without `terminal_id` keeps the old rule: a
same-namespace PID and start-time check, and unknown liveness from a foreign
namespace.

**Termination.** `kill()` uses `pane close`, which the spike verified ends the
whole tree. A caller may signal a process group as a fallback only when it
shares the recorded namespace and has re-verified the start time. Every other
`session_pid` consumer in `scripts/nogg` that reads `/proc` or sends a signal
(launch record, reservation probe, stop fallback) SHALL gate on namespace
equality.

**Tests.** The suite runs on the fake herdr. It covers:

- a fenced refusal before any side effect;
- the receipt fields;
- a socket-identity mismatch, which is refused as "not owned";
- a foreign-namespace record with a matching `terminal_id` that reports alive,
  using a reaped PID so that any local `/proc` read would fail the test;
- a restored pane with a new `terminal_id`, which reports vanished;
- no signal sent from a foreign namespace.

If the fake lacks `terminal_id` or the restart semantics, extend it only with
forms present in the committed spike fixtures.

### 6. A stopped server is a definite state with a recovery command (D2, TASK-HHB-005)

**Definite down.** The herdr backend SHALL report the records of a dedicated
namespace as *vanished*, not unknown, when both of these hold:

- `herdr --session <ns> status` exits 0 and reports `server: status: not
  running`;
- `herdr session list --json` reports that session with `running: false`.

A stopped server has no pane processes (spike facts; acceptance step 21). A
CLI failure, a timeout, a disagreement between the two answers, or an
unparsable answer stays unknown, as before. As a result, `session list` shows
these records as `failed` and `reap` reaps them. A same-Bead launch, including
`--resume`, is no longer refused as "a live lead session already covers".
That launch then starts the server under Decision 5.

**`scripts/nogg session herdr-server start`.** The command is idempotent:

- It verifies an owned running server, or starts the dedicated server with
  Nogging's config, scrubbed environment and receipt, through the same code
  path a launch uses.
- When fenced, it refuses with an explanation.
- When a running server fails the ownership checks, it refuses and names the
  failed check. The operator can then stop that server with `herdr --session
  <ns> server stop`; Nogging still never stops or updates a herdr server
  itself.
- Run host-side, it upgrades a legacy receipt.
- It writes no session record and creates no workspace or pane.
- It prints the resulting state.

The suite simulates a server stop with the fake herdr and covers: `failed` in
`list`, `reap`, a same-Bead launch that passes the live check, a CLI failure
that stays unknown, and the command's idempotent, fenced and foreign-server
paths.

### 7. Orphan panes are limited to the current checkout's records (D1, TASK-HHB-006)

`orphans()` SHALL receive the current checkout's full record set, in every
state including `retired`. A pane is an orphan only when both hold:

- its label equals the name of one of those records;
- no active record of this checkout owns it alive (or `starting`), as today.

A `sf-` pane whose label matches no record of this checkout is *foreign*. It
belongs to another checkout, or to a record that was deleted. A foreign pane
is never closed and never adopted. `session list` prints one NOTE with the
count of foreign Nogging panes and explains that they were not touched.
Unknown liveness still suppresses orphan handling, as before.

The suite gives two checkouts' record stores one fake herdr state. Cleanup in
checkout A never closes checkout B's live pane. A's own restored pane, whose
record has failed, is closed. A pane with no record anywhere is noted and kept.

### 8. No stray root shell pane (D8, TASK-HHB-007)

When `prepare()` creates the workspace, it SHALL store the `root_pane`
`{workspace_id, pane_id, terminal_id}` from its own `workspace create` reply in
`workspace.json` in the herdr state directory. After the next successful
`layout.apply` into that workspace, the backend closes that root pane with
`pane close`. Before closing, it re-checks that the pane is still unlabelled
and still has the stored ID and `terminal_id`.

A workspace now lives only as long as a session pane (spike fact: a workspace
disappears with its last pane). So an explicit `workspace_not_found` *error
reply* to `layout.apply` (nothing was created) recreates the workspace and
retries once. A lost or malformed reply still never triggers a second
`layout.apply`, which is the existing transport rule.

Root panes left by earlier versions are not closed automatically: `doctor`
reports them as a NOTE with their pane ID. The suite runs on the fake herdr:

- the root pane is closed after the first apply;
- the workspace is recreated after it vanishes;
- an operator's unlabelled pane that is not in `workspace.json` is kept.

### 9. Byte-based, bounded session log (D3, TASK-HHB-008)

`scripts/session-log-writer` is rewritten in Python using only the standard
library. Its path and positional interface (`<log> <max-bytes> <depth>`) stay
the same, so tmux `pipe-pane` and the PTY recorder are unchanged. The writer:

- reads stdin in chunks of at most 64 KiB (`os.read`) and appends each chunk
  at once through an `O_APPEND` descriptor, without waiting for a newline;
- before a write that would push the active file past `max-bytes`, writes
  only the remaining room, rotates (same `.N` naming; anything past `depth` is
  dropped) and continues with the rest, so no generation ever exceeds
  `max-bytes` and memory stays bounded by the chunk size;
- preserves bytes exactly, including escape sequences and invalid UTF-8;
- exits 0 at EOF and non-zero on a write error. The recorder already keeps the
  agent running if the writer fails.

`--contract` keeps `version` 1 and `positional` 3 and adds `features:
["byte-stream"]`. The existing helper-contract check (launch preflight and
`doctor`) requires that feature, so an outdated installed writer is caught.
`_archive_log()` archives the active log and every rotated generation
`<log>.1..N` under the same timestamp, so no generation is left behind.

The suite covers:

- a no-LF stream through a pipe that keeps the writer open: the log grows
  before EOF;
- a 3 MiB no-LF stream with a 1 MiB limit: every generation is at most 1 MiB,
  and `depth` is respected;
- byte-exact content;
- cleanup archiving every generation.

No PTY is needed.

### 10. Agent-specific submit verification (D4, D5, TASK-HHB-009)

**Codex.**

- A Codex `session nudge --message` first delivers through `codex_queue_send()`,
  the same path `session send` uses. When the queue accepts, the nudge is
  done.
- **Pane fallback** (thread unresolved, or the queue refuses). The nudge
  clears the input, types the text and submits it. Verification, here and in
  `send --verify`, uses a Codex composer classifier on the attribute capture.
  The composer line starts with `›`: dim text is a placeholder, and non-dim
  text is pending input.
- **Retry.** Pending input equal to the sent text gets one more submit. If
  the text is still pending after that, the command fails as unsubmitted.
- **Unidentifiable composer.** If the composer cannot be identified, the
  command fails as *unverified*. It never prints `nudged`.
- `Pasted Content` stays a pending-input signal.

**Antigravity.**

- **Composer.** The classifier treats the text between the last two
  full-width rule lines, on the line starting with `>`, as the composer.
- **Placeholder and input.** Dim composer text is a placeholder; non-dim
  composer text is pending input.
- **Ignored lines.** Everything below the lower rule is ignored, including
  the permanent status bar (`? for shortcuts … · <model> · <effort>`).
- **herdr status.** On herdr, an agent status of `working` or `done` seen
  after the submit counts as submitted. This is the replacement check Claude
  already has.
- **No extra Enter.** A submit is retried only while input is positively
  pending, so a delivered message never gets an extra Enter.

The generic last-line check is removed for these two agents. Pi keeps its
current behaviour.

**Fixtures** come from the committed spike captures
(`read/codex/idle-placeholder.ansi`, `read/agy/idle.ansi`), plus typed-input
variants derived from them and labelled as derived. The re-acceptance
(TASK-HHB-012) verifies the behaviour live. The suite uses the tmux stub, the
fake herdr and a `PATH`-stubbed `codex`. It covers queue delivery, a pending
retry and failure, an unidentifiable composer, Antigravity delivered with the
status bar present, and herdr `working`.

### 11. Codex exact resume is supported (D7, TASK-HHB-010)

**Decision: support it, do not drop it.** The spike verified `codex resume
<id>`. Records already hold `codex_thread_id`. Exact resume is the documented
recovery path on both backends.

- **Validation.** `session launch --agent codex --resume <id>` validates `<id>`
  as a UUID before any side effect. The record stores
  `codex_thread_id = <id>`, so `send`, `nudge` and kickoff reach the thread
  through `codex queue` without discovery.
- **Wrapper.** `scripts/session-launch` runs `codex resume <id>` with exactly
  the authority flags of a cold launch: sandbox, approval, writable roots,
  network, model, reasoning effort, cwd and read-only-root handling. It does
  *not* re-send the launch prompt as a new first message, because the resumed
  thread already carries it and a re-send would start an unsolicited turn.
- **Unsupported flags.** The flags `codex resume` accepts are checked against
  the installed Codex. Commit a `codex resume --help` capture under
  `scripts/fixtures/codex/`. If a required authority flag is not accepted, the
  resume is refused before any side effect. No flag is ever dropped silently.
- **Contract.** The `session-launch` contract adds the feature `codex-resume`,
  and launch preflight requires it for a Codex resume.

The suite uses a `PATH`-stubbed `codex` that captures argv. It covers:

- resume argv with no prompt;
- identical restricted and trusted flags;
- an invalid ID refused before side effects;
- a stub help that lacks a flag, which is refused;
- the record field.

This task shares its branch lane with TASK-HHB-009 (see below). Both build on
Codex thread-ID handling.

### 12. Documentation (TASK-HHB-011)

The task updates these documents:

- `docs/using-with-herdr.md`:
  - the host-namespace server start and the fenced refusal;
  - `session herdr-server start`;
  - recovery while the server is down;
  - checkout-scoped orphans;
  - no root pane;
  - terminal identity;
  - live logs.
- `docs/failure-recovery.md`: a server-down section and the orchestrator lock
  states.
- `docs/running-work-in-sessions.md`: the live byte log, and cleanup that
  leaves the shared tmux server running.
- `docs/using-with-codex.md`: exact resume.
- `docs/operating-model.md` and `docs/architecture.md`: the cleanup wording,
  the log writer, and the lock rule.

The previous acceptance report stays unchanged, because it is evidence.

### 13. Real Pi re-acceptance (TASK-HHB-012)

The re-acceptance is a live run on herdr 0.9.x with Claude, Codex and
Antigravity, plus a parallel tmux Lead. It produces a new unsigned report,
`docs/acceptance/<date>-herdr-hardening.md`, from the template. It repeats
every failed check of the previous run (12, 13, 15, 18, 22, 32, 34, 35) and
regresses the passed ones. It adds these checks:

- **D6.** Cleanup in a worktree whose records are all retired, while the
  Orchestration Agent runs, leaves the tmux server running.
- **Orchestrator lock.** With a lock older than the TTL and a live holder,
  `recover` shows it as held from both the host and the sandbox.
- **D10.** `task-done` from an implementation worktree ticks that worktree.
- **D8.** No root pane is left.
- **D9, both topologies:**
  - a sandboxed Lead's first herdr launch with the server down is refused;
  - the server is started host-side with `session herdr-server start`, and
    its namespace is checked against the host's;
  - a sandboxed Lead's herdr sessions are then alive, stoppable and listable
    from both sides.

Host-side steps are recorded as operator actions. Only the Product Owner
signs.

## Dependencies and parallel lanes

`A ← B` means A depends on B (`bd dep add A B`). The edges are explicit, not
inferred from task order.

Branches follow `<type>/harden-herdr-session-backend`. Tasks that can run at
the same time differ only in the `<type>` prefix, so each lane owns one
prefix. Tasks in the same lane run one after another: each deletes its
integrated branch before the next allocates it. The prefix only tells parallel
worktrees apart; each commit subject still carries its own Conventional type.

| Task | Complexity | Depends on | Branch prefix | Main files (ownership) |
| --- | --- | --- | --- | --- |
| HHB-001 tmux server kept (D6) | routine | — | `fix/` | `scripts/nogg` (`session_cleanup` tail), `scripts/lib/session_backend_tmux.py` |
| HHB-002 orchestrator lock | standard | — | `chore/` | `scripts/nogg` (orchestrator lock, `recover` lock section, `orchestrator status`, `doctor` lock line) |
| HHB-003 task-done broker (D10) | standard | — | `refactor/` | `scripts/nogg` (`task_done` client, sandbox contract check), `scripts/openspec-sandbox` |
| HHB-004 host-namespace herdr (D9) | complex | — | `feat/` | `scripts/lib/session_backend_herdr.py` (server, receipt, start, identity, live, kill), `scripts/nogg` (`session_pid` consumers), the fake herdr if needed |
| HHB-005 server-down recovery (D2) | standard | 004 | `feat/` | `scripts/lib/session_backend_herdr.py` (status, live), `scripts/nogg` (`session herdr-server`) |
| HHB-006 checkout-scoped orphans (D1) | routine | 005, 001 | `feat/` | `scripts/lib/session_backend_herdr.py` (`orphans`), `scripts/nogg` (`herdr_orphans` callers, list NOTE) |
| HHB-007 root pane (D8) | routine | 006 | `feat/` | `scripts/lib/session_backend_herdr.py` (`prepare`, `start`), `scripts/nogg` (doctor NOTE) |
| HHB-008 byte log writer (D3) | standard | — | `perf/` | `scripts/session-log-writer`, `scripts/nogg` (`_archive_log`, writer contract check) |
| HHB-009 submit verification (D4, D5) | standard | — | `test/` | `scripts/nogg` (pane input, verify, nudge region) |
| HHB-010 Codex exact resume (D7) | standard | 009 | `test/` | `scripts/session-launch` (Codex branch, contract), `scripts/nogg` (resume gating, record) |
| HHB-011 docs | standard | 001–010 | `docs/` | `docs/**` |
| HHB-012 Pi re-acceptance | complex | 011 | `docs/` | `docs/acceptance/<date>-herdr-hardening.md` |

Why each edge exists:

- **005 ← 004, 006 ← 005, 007 ← 006.** The herdr lane edits one module and
  the herdr end-to-end expectations. Each step also builds on the previous
  semantics: the definite-down state uses Decision 5's identities, orphans
  use that liveness, and the root-pane close sits in `start()`, which
  Decision 5 rewrites.
- **006 ← 001.** Both edit adjacent lines at the end of `session_cleanup()`.
- **010 ← 009.** The `test/` prefix lane. Both tasks touch Codex thread-ID
  handling, and resume must leave `codex_thread_id` usable by 009's queue
  nudge.
- **011 ← 001–010.** The docs describe the behaviour as finally implemented.
- **012 ← 011.** The acceptance checks the documented behaviour.

The lanes run as follows:

- **At start:** 001, 002, 003 (the herdr-independent safety lane), 004, 008
  and 009 can all begin at once, on six distinct prefixes.
- **Spines:** 004 → 005 → 006 → 007 runs on `feat/`, and 009 → 010 on
  `test/`.
- **Join:** everything → 011 → 012 on `docs/`.

Before allocating a dependent worktree, a Lead verifies that every
prerequisite execution commit is integrated into `develop`; Bead closure alone
is not enough. TASK-HHB-012 needs a host session that can reach the herdr
socket, start all three runtimes and run host-side commands. It is not
suitable for a sandboxed Codex worker. Every other task is suited to a
sandboxed Codex or Antigravity Lead.

## Risks / Trade-offs

- **Fenced callers cannot start herdr.** A sandboxed Lead that needs the
  server while it is down is refused and must ask the operator or the
  Orchestration Agent to run `session herdr-server start`. This is accepted:
  it is explicit, it happens only once per server lifetime, and it avoids a
  server that dies with a Lead.
- **A tmux server started from a sandbox has the same flaw.** Analysis shows
  that if a sandboxed Lead is the first to start `tmux -L nogging`, that
  server lives in the Lead's PID namespace and dies with it. In practice the
  always-on orchestrator keeps the tmux server alive. This change does not fix
  it; it is a candidate for a later change.
- **Socket identity as ownership evidence from a foreign namespace** is weaker
  than a PID check, because inode numbers are reused. Pairing the inode with
  `ctime_ns` and the config equality makes accidental acceptance negligible.
  Same-namespace callers keep the PID check.
- **Definite-down depends on two herdr answers agreeing.** Any doubt stays
  unknown, so the worst case is the old behaviour.
- **Branch lanes serialize 009 → 010.** This costs some parallelism and keeps
  to the 7-prefix convention.
- **Derived pane fixtures** might not match a later runtime build. The live
  re-acceptance is the backstop. The adapters fail closed (unverified),
  never open (false success).

## Migration / Rollback

- **tmux-only installs.** The only visible change is that the tmux server is
  no longer killed under other sessions.
- **Existing records and locks.** Legacy herdr records, receipts and
  orchestrator locks keep working under their legacy rules. A host-side `session herdr-server
  start` or the orchestrator's next restart upgrades them.
- **Mixed sessions.** Sessions launched before the update keep their old
  broker until they are relaunched; the `task-done` client then reports a
  relaunch.
- **Rollback.** Revert the commits. No state format becomes unreadable for
  the old code, because the new fields are additive.

## Open Questions

None for planning. Two facts are confirmed at execution time and recorded as
Bead evidence: which flags `codex resume` accepts (TASK-HHB-010), and whether
the fake herdr already reports `terminal_id` and stop semantics (TASK-HHB-004,
TASK-HHB-005).
