## Context

See proposal.md for scope and source #160. Research baseline was develop
`b73fc1f`; authoring started after fast-forward to `43d0c06`. The literal
`send-keys -l` transport, immediate Claude double Enter, unverified plain send
and kickoff, and queue success based only on exitcode remain present.
Isolated mocked probes confirmed those paths. The issue's paste-timing
explanation is plausible, not a live proof of Claude's internal mechanism.

The unsigned herdr hardening report records successful Codex queue deliveries,
but the operator's current fleet also repeatedly leaves queued kickoff text
unsent. Neither observation establishes a universal queue guarantee.
`SPEC-o1eu` also records kickoff entering Claude's trust dialog; #42 corrects
an earlier diagnosis: a dim suggested instruction is a placeholder, not
pending input. Both constrain readiness and retry decisions.

TASK-HSS-005 (`SPEC-culj`, PR #171, execution commit `6765d8c`) supplies
bounded clear and exact-message checks. It was closed during research, but
its PR was still open at authoring time. Preserve an explicit external
dependency and require integration, not just closure. TASK-HSS-002's tmux
namespace diagnostics are already integrated. The concurrent
`relaunch-on-orchestrator-restart` change owns orchestrator restart functions
and its guide paragraphs; this change does not edit those functions.

## Goals / Non-Goals

**Goals:** safe paste, finite startup waits, verified ordinary sends and
kickoffs for Claude/Codex/Antigravity on both backends, no blind duplication,
and independent small execution lanes. Preserve HSS's complete replacement
contract and exact conversation/role authority.

**Non-Goals:** runtime trust or permission acceptance, model changes, general
hook installation repair, external delivery services, changes to Pi delivery,
or automatic replay after ambiguous transport acceptance. Live tests never
send instructions to the existing orchestrator or other workers.

## Decisions

### 1. Test and execution discipline (every task)

- Each implementation task adds its named focused suite and runs `scripts/test`.
  No real Dolt or bd; CLI fixtures stub the tracker. No PID-range assumptions,
  `unshare`, real systemd or existing tmux server. Use injected clocks and
  captured/labelled synthetic panes rather than real sleeps to test deadlines.
- Clear inherited `NOGG_*`, `NOGGING_*`, `HERDR_*`, `TMUX` and `TMUX_TMPDIR` in
  fixtures; use scratch CODEX_HOME and a writable temporary npm cache. Never
  clear the real execution fence or export GIT_DIR around tests.
- Use stateful tmux and herdr fakes. Any Unix socket is under a short
  `/tmp/nogg.XXXXXX` directory with its length asserted below 108 bytes.
  A real transport check, if included, owns a fresh private tmux socket and
  creates its own server; it never assumes or touches a host server.
- Record the mapped spec requirement and design Decision in each task's Bead
  note. Leads read Decision 1, their own Decision, task and matching spec slice.
  No implementation or execution claims occur during this planning session.

### 2. Isolated tmux paste (TASK-RSI-001)

Keep `send_text(ref, text)` as the primitive: it transfers text but never
submits it. Replace literal send-keys with `load-buffer -b <unique> -` using
stdin, then `paste-buffer -p -r -d -b <unique> -t <target>`. `-r` preserves LF;
the local tmux manual confirms `-p` emits boundaries only if the application
enabled bracketed paste. Do not claim that paste alone proves processing or
submission. No paste without requested mode is silently considered verified.

Use a fresh operation UUID in a namespaced buffer name, not global `nogg`:
two planning/Lead sessions share the server. Best-effort delete-buffer in a
finally block covers failures, preserving the original error. Commands keep
the configured socket and fenced `-N` prefix. Never use clipboard switches or
write the message to a persistent file. Add optional stdin input to the
injected command runner and tmux command/invoke forwarding, retaining legacy
calls without that keyword when unused. Keep transport errors from echoing
stdin/message contents. Herdr's verified send-text interface stays unchanged.

Own the tmux `send_text` region, runner stdin plumbing and primitive docstring;
do not modify HSS namespace probes or key maps. Depend on SPEC-culj because
the transport is also used by its nudge path. Suite:
`scripts/session-paste-transport.test.sh`, checking exact stdin bytes including
Unicode, quotes and newlines, flags, unique buffers, concurrent interleaving,
cleanup on failure, no Enter and preserved fenced argv. Update the few old
tests that explicitly assert literal send-keys for changed delivery paths.

Alternative rejected: global paste buffer or a delay alone. The former races
between sessions; the latter leaves multiline transport implicit.

### 3. Bounded startup readiness and timing (TASK-RSI-002)

Add shared timing validation and `await_session_input_ready` in the existing
readiness region of scripts/nogg. Configuration, all finite numeric values
with booleans refused:

| Key | Default | Accepted range |
| --- | --- | --- |
| session_submit_delay_seconds | 0.3 | 0 through 5 |
| session_submit_verify_delay_seconds (existing) | 0.5 | greater than 0 through 5 |
| session_delivery_timeout_seconds | 15 | 1 through 120 |
| session_startup_timeout_seconds | 120 | 1 through 600 |

Validate all four before any message/key/queue side effect. Preserve the
existing verification interval as the polling interval; all deadlines use
monotonic time. Each subprocess/capture is bounded by the remaining budget;
check running state on each poll. Emit a waiting diagnostic at most once per
five seconds and a final missing-evidence remedy at expiry. No unbounded lock
waits: admission to delivery/kickoff locks also uses the operation's deadline.

Claude readiness requires an identified empty/placeholder composer and live
idle state, never a trust/permission dialog or limit. Codex requires the exact
live session and identified ready composer before initial kickoff; an active
thread alone does not establish startup readiness. Other sends can still
steer an already-working session if its composer is safe; startup idleness
is a kickoff-only requirement. Pi keeps its existing path.

Antigravity's current fixed 30-second `await_antigravity_first_turn` becomes
a compatibility wrapper around this bounded wait. Preferred evidence is a
validated fullyIdle Stop event belonging to this launch, combined with a safe
composer and no contrary live state. If a Stop event is delayed or missing,
two consecutive backend statuses idle/done with an empty composer, at least
one poll apart and from the exact recorded backend process, suffice. Unknown,
blocked, working, trust/permission or limit evidence never suffices. A stale
ready_at predating this launch does not suffice. Record readiness source/time
under the lifecycle lock, without fabricating a conversation ID or relaxing
exact-resume validation. Failure names the absent Stop/live evidence and
points to session log/watch and the hook diagnostic; no keys or queue call.

Own timing/readiness functions only, not send/nudge/submit callers. Suite:
`scripts/session-input-ready.test.sh`, covering >30-second readiness, missing
Stop with/without reliable fallback, stale events, process disappearance,
dialogs, deadlines and every invalid timing class on tmux and fake herdr.
Alternative rejected: fixed startup sleep or merely increasing 30 seconds;
neither distinguishes a ready composer from a blocked runtime.

### 4. Shared pane submission and default verification (TASK-RSI-003)

After RSI-001, RSI-002 and SPEC-culj are integrated, update send/nudge and
`_submit_pane_input`/`_verify_submitted`. Reuse HSS clear/exact-message helpers;
do not reimplement its ctrl+u/backspace sequence. A per-session delivery lock
serializes queue/pane operations from Nogging. Expose one internal already-
locked delivery routine, so nudge/send/kickoff never recursively acquire that
lock. Lock order is kickoff -> delivery -> short lifecycle writes; polling
never holds the lifecycle lock.

Ordinary pane send requires empty/placeholder before typing; actual input or
unknown refuses with the explicit `nudge --message` remedy, without clearing.
Nudge uses HSS's replacement checks. After transfer, poll for the operation's
exact message (using HSS normalization and provenance-bound collapsed paste
markers) within the delivery deadline before Enter. This handles slow paste
rendering. Unknown or merged text gets no Enter. Send never clears unrelated
input; nudge retains HSS's bounded cleanup on mismatch.

Wait submit_delay before ONE Enter. Verification is automatic for Claude,
Codex pane fallback and Antigravity; retain `--verify` as accepted syntax and
Pi's existing explicit behavior. A known composer that held this message
then becomes empty/placeholder confirms pane submission. An observed new
backend transition to working/done can also confirm; a baseline working
status or unknown box alone cannot. Without SGR, the operation's own known
empty baseline and exact plain box text can establish ownership, preserving
the existing conservative replacement path. Poll within the deadline; one
retry is permitted only while this same message is positively pending.
The retry sends one Enter after submit_delay, never another text injection.

Do not retry with Enter on unrelated input, suggestions, dialogs, empty or
unknown composers. Fail non-zero as unsubmitted/unverified after the bound;
do not print success. Include pending/unverified status in diagnostics without
message contents. Codex accepted-queue handling is replaced in RSI-005;
until then, this task's focused tests cover the pane route.

Suite: `scripts/session-submit-policy.test.sh`; stateful delayed-render,
swallowed-first-Enter, already-delivered, still-pending, merged/unknown,
placeholder, no-attributes, existing-working and HSS multiline regression
cases on both fakes. Update old unconditional-double-Enter expectations.
Alternative rejected: always two Enters or automatic clear-and-resend.

### 5. Pure Codex receipt reader (TASK-RSI-004)

Add `scripts/lib/session_codex_delivery.py`, imported only by the subsequent
integration task, and its verbatim installer manifest entry. This task can run
in parallel with transport/readiness: it does not edit scripts/nogg.

The caller supplies a resolved exact thread ID and a path verified from that
file's session_meta ID and cwd, never a closest-name or latest-conversation
guess. Snapshot inode/device, byte offset and any unfinished final line before
the queue request. Read only subsequently appended complete records, with a
1 MiB limit per poll and 4 MiB total per operation. Do not synchronously scan
all historical transcripts. A replaced/truncated source, inaccessible path,
unsupported shape or exhausted scan budget reports unknown.

Receipt is a fresh `response_item` user `message` whose input_text parts match
the exact supplied message after CRLF-to-LF normalization, in that exact
thread. The installed Codex 0.162.1 writes this shape; synthetic fixtures
retain only schema, not private text. Historical identical instructions,
assistant/tool text and other threads never count. A queue-created draft or
transport receipt alone never counts. Return receipt identity/offset or
unknown; no submission policy, subprocesses or copying content to durable
metadata. If later runtime formats cannot supply this evidence, integration
can use the known-composer path or must fail as unverified.

Suite: `scripts/session-codex-receipt.test.sh`: incremental records, partial
lines at snapshot and poll boundaries, Unicode, repeated historical messages,
wrong thread/cwd/role, rotation/truncation, missing files, limits and CRLF.
Include a scratch init/update packaging check for the new manifest entry.
Alternative rejected: matching arbitrary recent log text or trusting exit 0.

### 6. Codex queue delivery state machine (TASK-RSI-005)

Integrate RSI-004 into queue/send/nudge after RSI-003. Validate timing, acquire
the delivery lock and snapshot the target receipt source/composer BEFORE the
queue call. Bound the subprocess by the delivery deadline. Return structured
internal outcomes: not-attempted, refused-before-acceptance, accepted,
submitted and unverified; a boolean cannot express the needed distinction.

- Resolve only the exact recorded thread. Unresolved thread means no queue
  invocation and permits the existing verified pane fallback.
- Exit 0 means accepted, then wait for a fresh receipt. A fresh receipt means
  submitted with NO Enter, regardless of an unknown/empty composer.
- If the composer was empty/placeholder before queueing and then holds the
  operation's exact pending message, use RSI-003's delayed single Enter and
  at most one retry, without retyping. A sole collapsed marker counts only
  when that clean baseline and this operation establish its provenance.
- Accepted but empty/unknown/unrelated composer plus no receipt means
  unverified at deadline, not a pane fallback. A queue subprocess timeout or
  ambiguous failure is also unverified. Nonzero exit is not automatically
  proof that nothing was accepted: fallback requires a known pre-acceptance
  refusal from a committed CLI fixture. Otherwise do not resend.

Print `sent`/`nudged (codex queue)` only after submission evidence. Error text
distinguishes acceptance with unknown delivery and points to log/watch and a
deliberate operator nudge after inspection. Never auto-requeue or type again
after acceptance. Both plain send and --verify use this policy, as does nudge.
Suite: `scripts/session-codex-queue-delivery.test.sh`, covering accepted+pending
recovery, delayed receipts, busy-before-send, no evidence, definitive refusal,
timeout/ambiguous refusal, no duplicate text/queue calls and unknown composers.
Alternative rejected: blindly applying pane send as queue fallback on timeout.

### 7. Kickoff wiring and retry identity (TASK-RSI-006)

After RSI-002 and RSI-005, all kickoff variants, including launch --kickoff,
planning, specialist, explicit text and --change, use the same readiness wait
and verified delivery routine. Preserve role validation before any injection.
An Antigravity wait happens once per operation, not separately in kickoff
and send. Verify running state again after waiting.

Serialize kickoff with its own bounded lock, then delivery. Store only a
message SHA-256, launch identity, timestamp, and status (pending, submitted,
unverified) in a small kickoff_delivery record; no plaintext prompt. Write
pending immediately before the first possible transport side effect. On
success mark submitted and set existing kickoff_sent_at only then. On an
ambiguous failure/crash preserve pending/unverified. A matching repeated call
rechecks evidence but never requeues/retypes. It can submit positively owned
pending input using the shared bounded routine; confirmed repeats are no-ops.
A different explicit instruction is a new operator-directed attempt, not an
automatic replay; preserve Antigravity's existing one-kickoff-per-launch rule.
Persist only opaque source offsets/identity needed for receipt rechecks, never
transcript content. Timeout before any attempt leaves no delivered marker and
is safe to retry. Merge metadata under lifecycle lock to retain Stop events.

Suite: `scripts/session-kickoff-delivery.test.sh`: all roles and --change,
launch chaining, failed readiness, missing-Bead refusal, >30-second AGY start,
concurrent calls, delayed queue delivery, ambiguous repeat and late Stop event
metadata preservation, on both backend fakes. Do not claim or execute Beads.
Alternative rejected: marking kickoff_sent_at when text is merely queued.

### 8. Documentation and integration regression (TASK-RSI-007, TASK-RSI-008)

007 updates `docs/running-work-in-sessions.md`, `docs/using-with-codex.md`,
`docs/using-with-antigravity.md` and `docs/failure-recovery.md`: timing keys,
default verification, new send precondition, queue-accepted versus submitted,
unknown outcomes and no blind resend, startup timeout/hook diagnosis,
placeholders and HSS replacement. Own only delivery paragraphs; no #161
restart paragraphs. Add `scripts/session-delivery-docs.test.sh` for documented
keys/defaults and obsolete queue-equals-verified claims. Preserve old reports.

008 adds `scripts/session-delivery-integration.test.sh`: exercise the CLI in
a scratch installed consumer on both fakes, fresh init and update, three
agents, multiline input, slow readiness, queue draft, failure propagation and
no duplicate delivery. Test helper packaging and unchanged Pi route, HSS
clear behavior and backend selection. Run the full suite once after focused
checks; repeat only after a new change or failure. This may run alongside 007.

### 9. Live delivery-host acceptance (TASK-RSI-009)

After 007 and 008, a host-capable operator-supervised Lead runs disposable
sessions, its own tmux socket and Nogging-owned herdr panes. Repeat long and
multiline kickoff/send/nudge for Claude and Codex on both backends, early AGY
kickoff after launch, delayed first-turn and the missing-hook diagnostic,
concurrent kickoffs and deliberately pending input. Record CLI versions,
exact observed receipts, message identifiers, retries, deadlines and leftover
composer contents, without credentials or private prompts. This checks the
issue's Pi timing hypothesis rather than asserting it from fixtures.

Commit `docs/acceptance/<date>-reliable-session-input.md` unsigned, with empty
Signed-off-by and honest skipped/failed cases. Existing fleet sessions and the
orchestrator are untouched; host limitations become discoveries. This task
requires a host session and is not suitable for a fenced Codex Lead. No human
acceptance is manufactured from CI success.

## Dependencies and parallel lanes

`A <- B` means `bd dep add A B`, a blocking edge. Branches are
`<prefix>/reliable-session-input`. A reused lane starts only after its prior
branch is integrated and deleted. Read task/spec plus the named Decision;
every task also inherits Decision 1.

| Task | Complexity | Blocking prerequisites | Prefix | Ownership |
| --- | --- | --- | --- | --- |
| RSI-001 | standard | SPEC-culj | fix | tmux send_text, primitive doc, runner stdin plumbing |
| RSI-002 | standard | none | feat | timing and readiness functions only |
| RSI-003 | standard | 001, 002, SPEC-culj | fix | pane submit/verify, send/nudge and delivery lock |
| RSI-004 | standard | none | refactor | new Codex evidence module, manifest entry |
| RSI-005 | standard | 003, 004, SPEC-culj | fix | Codex queue/send/nudge integration |
| RSI-006 | standard | 002, 005 | fix | kickoff and launch kickoff chaining |
| RSI-007 | routine | 006 | docs | delivery guide sections and docs check |
| RSI-008 | standard | 006 | test | installed-consumer CLI integration suite |
| RSI-009 | complex | 007, 008 | docs | unsigned live report, host-only |

Why the edges exist: 001 uses HSS's nudge transport; 003 changes HSS's shared
helpers and needs paste/timing; 005 edits the shared send/nudge region and
needs both pane policy and Codex receipts; 006 consumes readiness and complete
delivery semantics; 007/008 describe and exercise the integrated result; 009
checks both documented behavior and regression coverage. The direct external
edges on 001, 003 and 005 are deliberate even where transitive blocking would
suffice. Markdown order and association with a change imply no dependencies.

Start 002 and 004 in parallel immediately; 001 can run alongside them once
SPEC-culj's execution commit is integrated. Functions owned by 001 and 002 in
scripts/nogg are disjoint. The fix lane is sequential. After 006, 007 and 008
run in parallel. Tasks 001-008 suit separate Codex/Antigravity Leads; 009 needs
host capability. Before allocating ANY dependent worktree, verify every
prerequisite execution commit is in develop, including external SPEC-culj;
its closed Bead alone does not authorize starting from an old baseline.

## Risks / Trade-offs

- Runtime rendering and rollout schemas change: unknown is an explicit
  failure, with committed fixture coverage and a live backstop.
- Bracketed paste is conditional and asynchronous: exact-message checks and
  processing waits still apply; do not advertise a fixed delay as a guarantee.
- Human input can race Nogging: only submit positively owned pending input;
  a changed or unidentifiable composer gets no speculative Enter.
- A receipt can be delayed while the agent works: accepted-but-unverified
  is visible; an automatic resend would create a worse duplicate instruction.
- Startup fallback weakens reliance on Stop hooks: require two exact-process
  idle/empty samples and no contradicting state; retain exact-resume checks.
- Main spec changes overlap HSS at the nudge seam: preserve HSS's requirement
  unchanged and depend explicitly on its implementation before integration.
- Same-file execution lanes: distinct function ownership and sequential fix
  tasks keep merge conflicts local. Re-read develop at each allocation.

## Migration Plan

Archive harden-session-supervision before this change: both modify the tmux
preservation requirement. This delta retains HSS's additional unsandboxed
caller scenario while explicitly limiting the argv exception to text transfer.
A scratch sequential archive of HSS then this change must preserve HSS's
wrapped-input and merged-text scenarios as well as this change's queue cases.
If archive order changes, the planner reconciles both deltas explicitly;
execution task order does not imply authority to archive either change.

Ship helper through init/update; absent timing keys get the documented
defaults. --verify remains valid. Existing records lacking kickoff_delivery
are readable; no old operation is invented as confirmed. Relaunch long-lived
workers to use the installed helper versions. No remote sync/push is part of
planning. Roll back execution commits together if needed; extra receipt and
kickoff metadata is additive and ignored by older readers.
