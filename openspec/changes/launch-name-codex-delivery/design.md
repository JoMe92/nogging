## Context

Research baseline: develop `2822000` (v3.0.0 prepared, not yet tagged). The
reporter of #236 ran a vendored copy; the reliable-session-input fixes (#207
`782ad4a`, #216 `e7a5b8e`, #218 `6e5ca9b`) are ancestors of the 3.0.0 release
prep `f39fb1d`, so an installation that predates them is expected to show the
older symptoms. Findings below were reproduced or read on this baseline, never
inferred from the issue text.

### Already fixed on develop (not planned again)

| Symptom | State on develop | Evidence |
|---|---|---|
| Claude collapses a paste to `[Pasted text #N]`; kickoff refused or lost | Fixed (#207) | `scripts/session-paste-placeholder.test.sh` |
| Claude shows only the tail of a long message | Fixed (clip rule) | `scripts/session-composer-clip.test.sh` |
| Kickoff typed while Claude still draws its banner / `/rc connecting` | Fixed (#216) | `_CLAUDE_STARTING_RE`, `scripts/session-input-ready.test.sh` |
| `send` prints success while text sits in the composer | Fixed (#218): delivery is verified and fails loudly | `scripts/session-submit-policy.test.sh`, `session-kickoff-delivery.test.sh` |
| Codex queue acceptance reported as delivered | Partly fixed (#218): exit 0 is no longer success; a fresh receipt is required | `scripts/session-codex-queue-delivery.test.sh` |

For #236 the practical answer on the Claude half is "upgrade"; the docs task
says so. Two Claude paths stay as they are and are not regressions: plain
`send` still refuses (loudly, nothing typed) when the composer is not
identifiable, and kickoff waits for readiness.

### Still failing (reproduced or recorded from live runs)

1. **Dotted or colon-bearing Bead IDs** (#235). `gen_session_name` keeps `.`
   (`[^a-z0-9_.-]` is its only rewrite), so `sf-lead-supply-doc-v0zu.1-…` reaches
   `tmux new-session -s`. tmux renames it; every later `-t` target names the
   old, dotted form. Reproduced for generation; the tmux rename is reported by
   the issue on tmux 3.x. herdr labels are not addressing targets but must stay
   equal to the record name.
2. **No cleanup after a failed start** (#235). `TmuxBackend.start` runs
   `new-session` then `wire_log`; a `pipe-pane` failure raises with no ref, and
   `_session_launch` only marks the record `failed`. Nothing kills the session.
   `settle_launch`, the pid query and the `running` transition have the same
   gap. `session stop` then correctly says "nothing to do", leaving an orphan.
3. **Codex `[Pasted Content N chars]`** (#236, SPEC-t374 note, HPS-007 step 3).
   Codex 0.162.1/0.163.0 collapsed a 1074-character kickoff, and the trusted
   Codex planner's 866-character planning kickoff in the HPS-007 re-acceptance
   was refused with the same message (later sends then reported an ambiguous
   queue result), so the collapse threshold is below 1000 and the rule must
   not assume it. Reproduced on develop with the real `_deliver_pane_locked`
   and a stateful composer: a long message leaves `› [Pasted Content 1000 chars]`; classification
   returns `input` with empty text, `_composer_holds_message` only accepts the
   exact bare `Pasted Content`/`[Pasted Content]` forms, and delivery raises
   "the composer did not hold exactly the message; nothing was submitted".
4. **First-turn acknowledgement swallows Enter** (#236). The launch wrapper
   passes the startup prompt as Codex's positional prompt, so a turn runs
   immediately. Codex readiness is only "empty composer, no working marker, two
   identical renders", which can pass before that turn starts or between its
   items; the kickoff is then typed into a busy composer and Enter does not
   submit. Antigravity 1.4.0 has the same shape and already gates on evidence
   that the startup turn ran; Codex has no such gate.
5. **`codex queue` to a busy session is lost** (SPEC-t374 note, three
   occurrences against a busy HPS-007 session, Codex 0.162.1). The call exits 0,
   no receipt appears, the composer stays empty and the text never shows, even
   after Esc. The same kickoff to an idle session was delivered. The root cause
   inside Codex is unknown and not ours to fix; what Nogging controls is not
   calling an interface whose acceptance is proven lossy in that state.

6. **A planner's process identity is lost across PID namespaces** (HPS-007
   step 4); see Decision 7.

The installed Codex here is 0.163.0; findings 3-5 were first seen on 0.162.1 (the
HPS-007 run used 0.163.0 for finding 3) and are re-probed by the acceptance
task, not assumed to hold.

## Goals / Non-Goals

**Goals:** consistent backend-safe names; no orphan after any failed launch;
Codex placeholder, startup-turn and busy-queue fixes with failing-first tests
that exercise the real code; independent small lanes; guidance for operators
on an older vendored copy.

**Non-Goals:** changing reliable-session-input's decisions (no blind resend, no
requeue, bounded waits); a Codex-side fix; Antigravity/Pi delivery; killing or
restarting the shared tmux server; changing what a healthy launched session does
after a refused kickoff.

## Decisions

### Decision 1: Test and CI discipline for every task

Each task's first commit adds its focused suite and shows it **failing on
develop** for the stated reason (the Bead note records the red output); the fix
commit turns it green. Suites run the real code: they assert
`not _is_legacy_mock()` (or run the CLI in a subprocess), never set
`TMUX_STUB_DIR` without `TMUX_STATEFUL_STUB`, and never patch the function under
test. Substrates are stateful fakes of the visible behaviour (a tmux fake that
rewrites `.`/`:` in names and parses `-t` like tmux; a composer fake that
collapses large pastes; a `codex` stub whose `queue` records its call).
`source scripts/lib/test-env.sh`; build stub agents with
`scripts/lib/test-agents.sh` (`stub_agent_binaries`/`use_agent_stubs`), writing a
test's own `codex` stub first because an existing stub is kept. CI has no real
`codex`, `agy`, `claude`, tmux server, herdr, Dolt or `bd`: stub `bd`, use fake
clocks, no PID-range assumption, no `unshare`, no live fleet input. Synthetic
panes and rollouts are labelled synthetic unless captured from a named version.

### Decision 2: One name helper, applied at generation and guarded in backends

`session_backend.py` gains a pure `safe_session_name(name)`: lowercase, `.` and
`:` become `_`, any other character outside `[a-z0-9_-]` becomes `-`.
`gen_session_name` and the orchestrator name use it, so the record `name`, log
and settings file names, `NOGG_SESSION_NAME`, tmux session and herdr pane/tab
label are the same string. Both backends' `prepare`/`start` refuse (before any
side effect) a name that `safe_session_name` would change, so a future caller
cannot reintroduce a silent rename. Distinct inputs may collapse (`a.1`,
`a_1`); the existing nonce and collision check already guarantee uniqueness.
Existing records and live sessions are untouched.

Rejected: sanitizing inside `TmuxBackend.start` and returning the rewritten name
(the launcher has already written the record and log paths from the original);
escaping with tmux's `=name` target (does not make `.`/`:` legal in the name).

### Decision 3: The backend owns undoing its own half-start; the launcher owns the rest

`TmuxBackend.start` and `HerdrBackend.start` clean up what they created if any
step after creation fails (tmux `kill-session` of that exact name; herdr
`pane close` of the created pane/tab, found by id or unique label), then
re-raise the original error. The launcher wraps everything from the `start`
call to the end of `settle_launch`: on any `Exception` it best-effort
`selected_backend.kill` of the known ref (or `{name, socket}`), records `failed`
with an `exit_reason` that includes whether cleanup succeeded, releases the
usage reservation exactly as today, and re-raises. Cleanup uses
`kill-session`/`pane close` only, never `kill-server`, and a cleanup error never
replaces the original. A kickoff refusal after the session is `running` is not a
launch failure: the healthy supervised session stays. Failure injection points
for tests: `pipe-pane` failing, `settle_launch` raising, and an exception between
`start` and the `running` transition.

### Decision 4: Codex placeholder as the operation's own pending paste

`_codex_composer_input` already reports `input` with empty text when
`Pasted Content` is visible. The new rule mirrors the Claude rule exactly:
the composer's sole content is one `[Pasted Content N chars]` token (N a
positive integer; an optional bare `Pasted Content` form is kept for the
existing fixtures), the message is long or multi-line, and **the composer was
verified empty before this operation pasted** (`clean_baseline`). "Long" is the
Claude rule's: 200 or more characters, or any newline. Extra typed
text, two placeholders, an image token or a placeholder present before the paste
stay refused ("did not hold exactly the message"). N is not compared with the
message length: Codex's counting is unproven, and a clean baseline is the
ownership evidence. The acceptance report records observed N against the
length so a later tightening can be justified. The rule lives in
`_delivery_composer_state`/`_composer_holds_message`, so send, nudge and
kickoff share it, and a footer hint such as `tab to queue message` outside the
composer rows is ignored.

### Decision 5: Codex is ready only after its startup turn finished; Enter is turn-gated

`session_codex_delivery.py` gains a pure `turn_state(path)` reading a bounded
tail of the exact thread's rollout for `event_msg` payloads `task_started`,
`task_complete` (both observed in a local Codex 0.163.0 rollout) and an
interruption/abort event if present; the result is `running`, `idle` or
`none`. A launch that passed a startup prompt records that fact; for such a
Codex session readiness additionally needs `turn_state == idle` with at least
one `task_started` from this launch; an unresolved thread or `none` waits and
names "no completed startup turn from this launch yet", failing at the startup
timeout like Antigravity's missing Stop. A resume or a launch without a prompt
expects no startup turn and keeps today's rule. Separately, for Codex the
delivery routine presses Enter only when the pane is not classified `working`
and, where the thread resolves, `turn_state != running`; it keeps waiting
(bounded by the delivery deadline) while the exact owned text stays pending, and
at the deadline fails with "text is still in the composer; Codex was busy; it
was not submitted", never claiming success. Existing bounded-retry limits
(at most the current number of Enters, only for positively identified owned
text) are unchanged. Unknown event names are ignored, so a future Codex cannot
make the reader throw.

### Decision 6: `codex queue` only for an idle session; busy means wait, then refuse

Before `codex queue` the delivery code establishes "not busy" from three signals:
the pane is not classified `working`, the backend agent status is not
`working`/`blocked`, and `turn_state != running` when the thread resolves. A busy
session is polled at the verify interval until idle or the delivery deadline.
At the deadline the call refuses with "Codex is busy; nothing was queued, typed
or keyed; retry when idle, or attach and type it yourself"; `codex queue` is
**not invoked**. On an idle session behaviour is unchanged: accepted plus fresh
receipt is success, accepted without receipt or pending text stays the
unverified error and is never requeued, retyped or pane-sent. The error text
adds the thread id (first 8 characters) and receipt-scan outcome so a wrong
thread binding is diagnosable. `nudge --message` shares the rule.

Trade-off, stated for the Product Owner: a long-running Codex turn can no longer
be steered through `send`. That is loud and recoverable; the alternative that
existed was silent loss. Rejected here: typing into a busy composer and pressing
Tab (Codex's native queue gesture), because its semantics on 0.162.1/0.163.0
are unverified; the acceptance task probes it so a later change can adopt it.
Risk recorded, not planned: `resolve_codex_thread_id` picks the earliest
same-cwd rollout since launch, which could bind a session to the wrong thread;
the improved diagnostic is the only change now.

### Decision 7: Planner process identity is captured where it is visible

Finding 6 (HPS-007 step 4, `docs/acceptance/2026-10-18-planning-robustness.md`
on `test/harden-planning-sessions`): a Claude planner launched by a fenced
Codex Lead onto a host-owned private tmux socket got a record with a PID but
`session_pid_start: null` and `session_pid_ns: null`, and no planning lock.
Code reading explains it: `_session_launch` computes `process_start(pid)` and
`pid_namespace(pid)` from the **launcher's** `/proc`; `TmuxBackend.prepare`
admits fenced callers to the host server, whose pane PID is invisible from the
caller's PID namespace, so both come back `None`; `planning_session_context`
then refuses ("planning session ownership is unavailable") because it requires
a truthy `session_pid_start`, so that planner can never run `plan-begin`. The
herdr path already stores server-namespace identities for this reason. The
socket name is irrelevant; the cause is the launcher/server namespace split, so
this is a product gap on a path the code explicitly allows, not a scratch
artifact. The Claude-specific run is not reproduced here, so the task is
diagnostic-first:

1. Failing test: baseline (identity visible) passes; with the launcher's
   identity reads failing for the backend-reported PID (injected, no `unshare`,
   no PID-range assumption) the record has null fields and `plan-begin` in that
   session context is refused. If this does not fail on develop, the task
   documents the actual cause in `failure-recovery.md`, files a discovery and
   stops without a code change.
2. Fix: the launch wrapper runs as the pane PID through its whole `exec` chain
   inside the server's namespace, so it writes a private receipt
   (`pid`, process start token, PID namespace) beside the record; when the local
   reads fail the launcher reads the receipt within the settle window, accepts
   it only if its pid equals the backend's pane PID, and stores the values with
   `session_pid_identity_source: wrapper`. For the `planning` role, which needs
   the identity to own the lock, a launch with no provable identity fails
   before kickoff, is cleaned up per Decision 3, and names the remedy (launch
   from an unsandboxed shell). Other roles keep running with the null fields and
   a launch NOTE. `planning_lock_live` already treats a foreign namespace as
   "cannot be disproved", so no liveness rule changes.

### Decision 8: Branches and ordering

Branches are `<prefix>/launch-name-codex-delivery`, one distinct prefix per task
where possible (`fix`, `refactor`, `feat`, `chore`, `perf`, `docs`, `test`); the
prefix is a label, not a claim about the change's nature. Only seven branch
types exist for eight tasks, so the planner-identity task reuses `fix` after
001 is integrated. Real conflicts are managed by explicit edges, not prefixes:
002 follows 001 (both edit the tmux backend `start`); 005 follows 004 (it reuses
`turn_state`); 006 follows 002 (it relies on launch cleanup); 003 and 004 touch
different functions and run in parallel. Documentation and acceptance wait for
every code task.

### Decision 9: Documentation and acceptance

The docs task states, per symptom, which version fixed it (#207/#216/#218 in
3.0.0), what an older vendored copy shows, the dotted-ID rule, the busy-Codex
rule and recovery, and adds a changelog entry under Unreleased. The acceptance
task is the only one needing a host with real tmux, Codex and (optionally)
herdr. It uses a private tmux socket and herdr namespace in a scratch consumer,
touches no fleet session, runs real-version probes for items 1-6 (including a planner launched from a fenced caller onto the host socket), records
versions and honest outcomes including skips, and leaves `Signed-off-by` empty.

## Risks / Trade-offs

- The Codex rollout event names are read from Codex 0.163.0 and may change;
  unknown names are ignored and readiness then times out loudly rather than
  proceeding on a guess.
- A strict startup-turn gate can refuse a kickoff on a Codex whose rollout is
  unreadable; the message names the missing evidence and the manual step.
- Refusing queue to a busy Codex is a behaviour narrowing, documented.
- 0.162.1 findings may not reproduce on 0.163.0; the acceptance report decides.

## Open Questions

1. Does Tab-to-queue in the Codex composer reliably deliver to a busy session?
   (Probed in acceptance; adoption would be a separate change.)
2. Is Codex's "N chars" the message's code-point count? (Recorded, not gating.)
