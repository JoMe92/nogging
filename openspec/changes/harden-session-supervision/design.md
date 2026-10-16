## Context

The baseline is `develop` at 18efc57 plus the planning commit that archives
`harden-herdr-session-backend`. That change's real Pi re-acceptance,
`docs/acceptance/2026-10-16-herdr-hardening.md`, ended
**pass-with-deviations**. Its discoveries N1–N4 are recorded on `SPEC-dcuq`,
and the hardening design's *Risks* section names one more hazard. This is
the code as it stands at the baseline:

- **tmux server in the sandbox.** `scripts/openspec-sandbox` (`supervise`)
  runs every execution runtime under `unshare --user --map-root-user --mount
  --pid --fork --kill-child=KILL --mount-proc`. It sets
  `NOGG_OPENSPEC_FENCED=1` for the nested runtime. `TmuxBackend.command()`
  runs `tmux -L <socket> …` unchanged for every caller. If no server is
  running, `new-session` forks a new server inside the caller's namespaces.
  That server, and every session started on it later, ends when the
  sandboxed Lead ends: the Orchestration Agent, other Leads and planners. The
  server also inherits the Lead's mount namespace, where `openspec/` is
  read-only. herdr already has a fenced refusal (hardening Decision 5); tmux
  has none.
- **N4.** `LOCKS = ROOT / ".nogging/locks"` is local to each checkout. The
  orchestrator lock (`acquire_orchestrator_lock`, `classify_orchestrator_lock`,
  `orchestrator_status`, the `recover` lock section) uses `LOCKS`. The
  planning lock already uses the canonical `PLANNING_LOCKS`, resolved from
  `canonical_repository_state(ROOT)["locks_dir"]`. `repo_slug()` takes
  `ROOT.name`, so the singleton session name and the unit name change with
  the worktree directory. `orchestrator_live_session()` reads the current
  checkout's session records. From a worktree, the lock therefore reads as
  `free`, no orchestrator appears to be running, and the unit is called
  `nogg-orchestrator-<worktree-dir>.service`.
- **N1.** `task_done()` sends `{"bead_id", "checkout"}` to
  `NOGG_TASK_DONE_SOCKET`. When the reply contains `only one closed Bead
  identifier`, which is the refusal of a pre-update broker, it sends
  `{"bead_id"}` again. An old broker then ticks the launch checkout, so D10
  comes back. The retry came in with commit `5c914dd`, and no suite asserts
  the designed behaviour.
- **N2.** `session_nudge(name, message)` sends one `ctrl+u`, types the text,
  submits it and verifies it. In Claude Code, `ctrl+u` deletes only back to
  the start of the current *visual* row. With two-row wrapped pending input,
  the first row stays, and the message is appended to it. Verification
  checks only whether input is still pending afterwards. So on herdr the
  merged text was submitted and reported `nudged`, and on tmux it stayed
  pending and failed with `message still unsubmitted after a retry`. Both
  backends have `capture_attributes`, so the same classifiers run on both.
- **N3.** `docs/using-with-herdr.md` quotes the advisory as `NOTE N foreign
  Nogging pane(s) active on herdr server (not managed by this checkout)`.
  `scripts/nogg` prints `NOTE: <N> foreign herdr pane(s) left untouched`.

## Goals / Non-Goals

**Goals:**

- A shared tmux server is only ever born in the host namespace, and one that
  was born elsewhere is visible.
- An operator or Lead in any worktree sees the true orchestrator lock and
  cannot start a second orchestrator.
- `task-done` matches hardening Decision 4 for mixed versions.
- `nudge --message` submits exactly the requested text or nothing, on both
  backends.
- The herdr guide quotes the real advisory.
- A short live re-check of the affected steps.

**Non-Goals:** see `proposal.md`.

## Decisions

### 1. Test discipline for GitHub runners (every task)

The hardening rules still apply to every new or changed suite:

- **No Dolt and no real `bd`.** Stub `bd` through `beads_command` or a `PATH`
  stub.
- **No PID-range assumptions.** To get a dead PID, start a child and reap
  it. To get a live one, keep a child running. Treat namespace identities as
  opaque strings. Inject a foreign namespace by replacing the one function
  that reads namespace links.
- **No `unshare`.** Never run `openspec-sandbox supervise` in a test.
  Simulate a fenced caller with `NOGG_OPENSPEC_FENCED=1`.
- **Short socket paths.** Create every test socket under `mktemp -d
  /tmp/nogg.XXXXXX`, never under `$TMPDIR` or the repository path, and
  assert that the path is shorter than 108 bytes. A test that needs tmux's
  own socket layout sets `TMUX_TMPDIR` to such a directory.
- **Clean environment.** Unset inherited `NOGG_*`, `HERDR_*`, `TMUX` and
  `TMUX_TMPDIR`.
- **One suite per task.** Each task adds its own `scripts/<name>.test.sh`.
  Existing suites change only where they asserted the defect being fixed.

### 2. A fenced caller never starts the shared tmux server (TASK-HSS-001)

- **No start from the sandbox.** When `NOGG_OPENSPEC_FENCED=1`,
  `TmuxBackend.command()` SHALL put tmux's global `-N` flag ("do not start
  the server") before every command. tmux 3.2, the documented minimum, has
  it (verified on tmux 3.5a). With the flag, `new-session` and any other
  command fails while no server runs; it never forks one. Unfenced argv stays
  byte-identical.
- **Refusal before side effects.** `TmuxBackend` gains `prepare(name, cwd)`.
  `session launch` already calls `prepare` at the point where herdr's fenced
  refusal runs, before the record, the effective settings and the log exist.
  When the caller is fenced, `prepare` runs `list-sessions`. If the listing
  fails, `prepare` refuses with: `tmux server -L <socket> is not running; a
  sandboxed session cannot start it, because it would end with this session;
  launch from an unsandboxed shell (the operator or the Orchestration
  Agent)`. A listing that fails for another reason refuses with its error;
  it fails closed. An unfenced caller skips the check, so its behaviour is
  unchanged.
- **Race.** If the server exits between `prepare` and `new-session`, the
  `-N` start fails. The record is then marked `failed` like any failed
  start, and no server appears in the sandbox.
- **Rejected alternatives:**
  - *A `session tmux-server start` command*, like herdr's. A tmux server
    exits after its last session (`exit-empty on`). Keeping an empty one
    alive needs `exit-empty off`, which conflicts with the D6 cleanup rule
    (stop only an empty server). The refusal points to an unsandboxed
    launch instead, and that launch starts the server in the host namespace
    as a side effect.
  - *A read-only bind of the tmux socket directory inside the sandbox.* It
    would also stop a Lead's own test suites that start private tmux
    servers.
  - *A broker operation.* It would widen the broker's one narrow purpose.
- **Residual risk.** An agent that runs `tmux -L nogging new-session`
  itself, outside `scripts/nogg`, can still start a server in the sandbox.
  Decision 3 makes such a server visible.
- **Suite:** `scripts/session-tmux-fenced-server.test.sh`, using the tmux
  `PATH` stub that records argv. It covers:
  - `-N` present on every fenced command and absent on every unfenced one;
  - a fenced launch with the stub reporting no server: refused with the
    message, and no record, settings or log file is created;
  - a fenced launch with a running stub server: it proceeds;
  - the race: `new-session` fails after a successful `prepare`, the record
    ends `failed`, and the stub never sees a server-starting call without
    `-N`.

### 3. A tmux server in another namespace is reported (TASK-HSS-002)

- **Probe.** One helper SHALL find the dedicated server's process without
  trusting tmux's own `#{pid}`, because that value belongs to the server's
  namespace. The helper:
  - connects to the dedicated socket path, the path tmux itself uses:
    `${TMUX_TMPDIR:-/tmp}/tmux-<uid>/<socket>`;
  - reads `SO_PEERCRED` and closes the connection. The kernel reports the
    listener's PID as seen in the caller's PID namespace, or `0` when that
    PID is not visible there;
  - for a visible PID, reads its `ns/pid` and `ns/mnt` links through one
    function, which the suite replaces.
- **Classification:**

  | Caller | Observation | Class |
  | --- | --- | --- |
  | any | socket missing or connection refused | `down` |
  | unfenced | visible PID, same PID and mount namespace as the caller | `host` |
  | unfenced | visible PID, different PID or mount namespace | `sandboxed` |
  | fenced | PID `0` (not visible from the sandbox) | `outside` |
  | fenced | visible PID (inside the caller's own sandbox) | `sandboxed` |
  | any | any other error | `unknown` |

- **Reporting:**
  - `doctor` prints a WARN for `sandboxed`. The WARN names the PID and says
    that every session on the server ends with that namespace. Like every
    WARN, it does not change `doctor`'s exit status.
  - `session list` prints one NOTE for `sandboxed`.
  - `orchestrator status` prints a `tmux server:` line with the class.
  - `orchestrator run` and an unfenced `session launch` print a WARN line
    when they start or adopt a session on a `sandboxed` server, and then
    continue. A refusal would leave no orchestrator for as long as the Lead
    runs.
  - Nothing ever kills, restarts or signals the server. `docs/failure-recovery.md`
    names the operator's choices.
- **Suite:** `scripts/session-tmux-server-namespace.test.sh`. A Python
  process stands in for the server and listens on
  `$TMUX_TMPDIR/tmux-<uid>/nogging`, under a short `mktemp` directory. The
  suite asserts the path length, injects namespace strings and checks every
  row of the table, plus the `doctor`, `list` and `status` lines. It sends
  no signal and issues no `kill-server`.

### 4. The orchestrator lock, session name and unit come from the main checkout (N4, TASK-HSS-003)

- **One resolver.** An orchestrator home SHALL be the main checkout reported
  by `canonical_repository_state(ROOT)`, which also places the planning lock.
  Only where that resolver cannot run (no Git checkout, as in pure helper
  tests) does the current root stand in, as `PLANNING_LOCKS` already does.
- **What it governs:**
  - the lock path `<main>/.nogging/locks/orchestrator.lock`, used for
    acquire, release, the classifier's default path, `orchestrator status`,
    the `recover` lock section and `doctor`;
  - the slug, from the main checkout's directory name, and with it
    `nogg-orchestrator-<slug>` and `nogg-orchestrator-<slug>.service`,
    including the name `session launch --role orchestrator` gives itself;
  - the live-session lookup, which reads the orchestrator record in the main
    checkout's session store.
- **Linked worktrees.** `orchestrator run` in a linked worktree SHALL refuse
  before it takes the lock, naming the main checkout. `orchestrator status`,
  `stop` and `restart` act on the canonical unit from any checkout.
- **Leftovers.** A checkout-local `orchestrator.lock` in a linked worktree is
  never read as the lock. `recover` and `doctor` report it as a NOTE with its
  path.
- **Migration.** The live orchestrator's lock already sits in the main
  checkout, which is the canonical location, so nothing moves.
- **Suite:** `scripts/orchestrator-canonical-lock.test.sh`. It uses a
  temporary repository with one linked worktree, stubbed `bd`, `systemctl`
  and `loginctl`, a live child process as the holder, and a lock in the main
  checkout. It covers:
  - from the worktree, `recover`, `orchestrator status` and `doctor` report
    the lock as held and print the canonical unit name;
  - `orchestrator run` from the worktree is refused, and no lock is written
    there;
  - a leftover worktree-local lock is reported and ignored;
  - the main checkout behaves exactly as before.

### 5. `task-done` reports a relaunch instead of retrying (N1, TASK-HSS-004)

- **No retry.** `task_done()` SHALL send exactly one broker request,
  `{"bead_id", "checkout"}`. When the reply is the pre-update refusal (`only
  one closed Bead identifier`), the client fails with: `task-done: this
  session's sandbox broker predates checkout-aware ticks; relaunch the
  session and run task-done again; nothing was ticked`. It exits non-zero,
  and every other refusal also gets no retry.
- **No fallback.** The client never falls back to a local tick. Inside the
  sandbox, `openspec/` is read-only.
- **Suite:** `scripts/task-done-mixed-broker.test.sh`. A Python broker stub
  listens on a short socket path and records each request. It covers:
  - the old refusal: one request carrying both keys, the relaunch message,
    a non-zero exit and an unchanged `tasks.md`;
  - a current broker: its success output is printed;
  - any other refusal: no second request.

### 6. `nudge --message` replaces wrapped pending input completely (N2, TASK-HSS-005)

These rules apply on both backends to every agent with a composer
classifier: Claude, the Codex pane fallback, and Antigravity. A Codex
message that `codex queue` accepts never touches the pane. Pi and any other
runtime keep their current behaviour.

1. **Clear.** The nudge reads the composer.
   - While it shows `input`, the nudge sends `ctrl+u` and reads the composer
     again. It keeps going only while the text gets shorter, with at most 8
     presses. This clears a wrapped buffer one visual row at a time.
   - If input is left, the nudge sends `backspace` once for each remaining
     character plus once for each composer row, and reads again. It refuses
     instead when more than 4096 keys would be needed.
   - The composer must end up `empty` or `placeholder`. If it is not, or if
     it reads as `unknown` at any point, the nudge fails with `<name>:
     pending input could not be cleared; nothing was typed or submitted`
     and exits non-zero.
2. **Type and compare.** The nudge types the message and reads the composer.
   It goes on only if the composer holds exactly the message. The
   comparison ignores whitespace, because wrapping re-flows rows. A
   composer that shows only the runtime's own collapsed-paste marker, and no
   other character, also counts as holding the message. Only marker forms
   from committed captures count, and Codex `Pasted Content` is already one.
   For any other content, the nudge clears the composer again as in step 1
   and fails with `<name>: the composer did not hold exactly the message;
   nothing was submitted`.
3. **Submit.** Submission and its one-retry verification are unchanged.

- **The `backspace` key.** It joins the backend key set. tmux sends
  `BSpace`. For herdr, the implementer checks the key name against the
  installed herdr 0.9.x and records it as Bead evidence. If herdr has no
  such name, the herdr backend sends the DEL byte (0x7f) through `pane
  send-text`.
- **Fixtures** are derived from the committed `scripts/fixtures/claude-panes`
  captures and labelled as derived:
  - a two-row wrapped pending input;
  - the state after one `ctrl+u`, with only the second row cleared (the live
    N2 observation);
  - a stale row merged with the message.
- **Suite:** `scripts/session-nudge-clear.test.sh`, run on the tmux stub and
  on the fake herdr, with stateful captures. It covers:
  - wrapped input cleared by repeated `ctrl+u`, then the exact message
    typed and submitted;
  - no progress with `ctrl+u`, then the `backspace` fallback clears;
  - a composer that never clears: the nudge fails, with no text typed and no
    Enter;
  - a merged composer: no Enter, and the nudge fails;
  - a clean prompt, the Codex queue path and Pi, all unchanged.

  The existing nudge suites stay unchanged.

### 7. The herdr guide quotes the real advisory (N3, TASK-HSS-006)

`docs/using-with-herdr.md` *Checkout-scoped orphan panes* SHALL quote
`NOTE: <N> foreign herdr pane(s) left untouched`. The suite
`scripts/docs-herdr-foreign-note.test.sh` takes the advisory's format string
from `scripts/nogg` and asserts that the guide quotes it, so the two cannot
drift apart again. No behaviour changes.

### 8. Documentation (TASK-HSS-007)

- `docs/running-work-in-sessions.md`: the fenced tmux refusal and its
  remedy; the nudge clear and exact-message check.
- `docs/failure-recovery.md`:
  - a tmux server born in a sandbox, with its symptom (every session ends
    together), its diagnosis (`doctor` WARN, `orchestrator status`) and the
    operator's choices: let the Lead finish, or stop the server
    deliberately, knowing that every session on it ends;
  - the orchestrator lock as seen from a worktree;
  - `task-done` asking for a relaunch.
- `docs/operating-model.md` and `docs/architecture.md`: the host-only birth
  rule for the shared tmux server, and the orchestrator lock and unit
  resolved from the main checkout.

The previous acceptance reports stay unchanged, because they are evidence.

### 9. Short Pi re-acceptance (TASK-HSS-008)

This is a live run on the Pi. It produces a new unsigned report,
`docs/acceptance/<date>-session-stability.md`, from the template, with only
these checks:

- **tmux birth.** The run uses a throwaway `session_tmux_socket`, set only
  in the acceptance worktree's uncommitted config and reverted before the
  report commit. That way the shared server and the Orchestration Agent are
  never stopped. The checks:
  - with the throwaway server down, a sandboxed Lead's tmux launch is
    refused, and the state directory is unchanged;
  - an unsandboxed launch starts the server, and the probe classifies it as
    `host`;
  - the sandboxed Lead's own tmux launch then works;
  - stopping that Lead leaves the server and its other sessions running.
- **N4.** From an implementation worktree, `recover`, `orchestrator status`
  and `doctor` show the live orchestrator's lock as held and print the
  canonical unit name. `orchestrator run` from the worktree is refused.
- **N1 and D10.** `task-done` from the task's implementation worktree ticks
  that worktree. This is the live tick that hardening step 38 could not
  show. The old-broker path is covered by the suite, unless a pre-update
  session is still running at the time.
- **N2.** Hardening step 43, repeated on tmux and on herdr with Claude:
  wrapped pending input is replaced by exactly the message. Steps 9, 12 and
  15 are repeated as regression checks.
- **N3.** The foreign-pane NOTE from hardening step 34 matches the guide.

Host-side steps are recorded as operator actions. Only the Product Owner
signs. Switching the default backend to herdr stays out of scope.

## Dependencies and parallel lanes

`A ← B` means A depends on B (`bd dep add A B`). The edges are explicit, not
inferred from task order.

Branches follow `<type>/harden-session-supervision`. Tasks that run at the
same time differ only in the `<type>` prefix, so each lane owns one prefix.
Tasks in the same lane run one after another: each deletes its integrated
branch before the next allocates it. The prefix only tells parallel
worktrees apart; each commit subject still carries its own Conventional
type. The free `chore/<topic>` form is also available as an extra lane.

| Task | Complexity | Depends on | Branch prefix | Main files (ownership) |
| --- | --- | --- | --- | --- |
| HSS-001 fenced tmux start | standard | — | `fix/` | `scripts/lib/session_backend_tmux.py` (`command`, new `prepare`) |
| HSS-002 tmux server namespace | standard | 001, 003 | `fix/` | `scripts/lib/session_backend_tmux.py` (probe, launch WARN in `prepare`), `scripts/nogg` (`doctor`, `session list` NOTE, `orchestrator status`/`run`) |
| HSS-003 canonical orchestrator | standard | — | `chore/` | `scripts/nogg` (orchestrator home, lock, slug, unit, live lookup, `recover` lock section, `doctor` lock line) |
| HSS-004 task-done relaunch (N1) | routine | — | `refactor/` | `scripts/nogg` (`task_done` client) |
| HSS-005 nudge clear (N2) | standard | — | `feat/` | `scripts/nogg` (nudge region), `scripts/lib/session_backend.py` (`KEYS`), the key maps of both backends |
| HSS-006 herdr guide wording (N3) | routine | — | `docs/` | `docs/using-with-herdr.md` |
| HSS-007 docs | standard | 001–006 | `docs/` | `docs/**` |
| HSS-008 Pi re-acceptance | complex | 007 | `docs/` | `docs/acceptance/<date>-session-stability.md` |

Why each edge exists:

- **002 ← 001.** The `fix/` lane. Both edit the tmux backend module, and
  the probe's fenced classes build on the fenced semantics of 001.
- **002 ← 003.** Both edit `orchestrator status`, `orchestrator run` and
  `doctor`, and the probe line belongs next to the canonical lock line.
- **007 ← 001–006.** The docs describe the behaviour as finally
  implemented.
- **008 ← 007.** The acceptance checks the documented behaviour.

The lanes run as follows:

- **At start:** 001, 003, 004, 005 and 006 can all begin at once, on five
  distinct prefixes.
- **Spines:** 001 → 002 on `fix/`, and 006 → 007 → 008 on `docs/`.

Before allocating a dependent worktree, a Lead verifies that every
prerequisite execution commit is integrated into `develop`; Bead closure
alone is not enough. TASK-HSS-001 to TASK-HSS-007 suit sandboxed Codex or
Antigravity Leads. TASK-HSS-008 needs a host session that can run host-side
commands, launch sandboxed and unsandboxed sessions, and drive Claude on
both backends. It does not suit a sandboxed worker.

## Risks / Trade-offs

- **A fenced Lead cannot bring up tmux.** When the shared server is down, a
  sandboxed Lead's tmux launch is refused until someone outside the sandbox
  launches a session. In practice the always-on orchestrator keeps the
  server up. The refusal is explicit, and it prevents a server that dies
  with the Lead.
- **Raw tmux in the sandbox.** An agent that bypasses `scripts/nogg` can
  still start a server there. Decision 3 makes that visible; it does not
  prevent it.
- **Reporting, not repairing.** A server born in a sandbox keeps running
  until its namespace ends. Nogging never kills it, because that would end
  every session on it.
- **`SO_PEERCRED` sees the listener.** For tmux, the listener is the server
  process itself. If a later tmux passed its socket to another process, the
  class would become `unknown` or wrong; the WARN is advisory only.
- **The clear sequence is runtime-specific.** Row-wise `ctrl+u` is the
  observed Claude behaviour. The bounded `backspace` fallback covers a
  runtime where `ctrl+u` makes no progress. In every case the nudge fails
  closed, never open: a composer that it cannot confirm as empty, or as
  holding exactly the message, gets no Enter.
- **`session send` still merges.** It types without clearing. Applying the
  same rules there is a candidate for a later change.
- **Derived fixtures** might not match a later runtime build. The live
  re-acceptance is the backstop.

## Migration / Rollback

- **Unfenced callers** see no tmux change: their argv is byte-identical.
- **Fenced sessions launched before the update** keep the old code until
  they are relaunched. A tmux server that an old session started in its
  sandbox shows up in `doctor` once the update is in place.
- **The orchestrator lock** already lives at the canonical path. The
  systemd unit name in the main checkout is unchanged.
- **Rollback.** Revert the commits. No state format changes.

## Open Questions

None for planning. Two facts are confirmed at execution time and recorded as
Bead evidence: the herdr key name for backspace (TASK-HSS-005), and whether
Claude Code 2.1.x clears a further row on a repeated `ctrl+u`
(TASK-HSS-005, live in TASK-HSS-008).
