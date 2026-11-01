# session-observability Specification

## Purpose

Defines observable agent activity, operator input delivery and usage-limit recovery for supervised Nogging sessions.

## Requirements

### Requirement: Watch classifies a session's live state via a per-agent adapter

`scripts/nogg session watch` SHALL classify each named or running session's
current state from one evidence order for every agent: a fresh structured event,
then a Codex rollout turn state, then herdr `agent_status`, then the pane adapter
keyed off that session's recorded `agent` field, never a single global keyword
match. Pane classification SHALL strip lines matching the adapter's `ignore`
patterns before checking state, and SHALL consider only the pane's last
approximately 15 lines, not its full scrollback. The classified state SHALL be one
of `working`, `waiting_background`, `idle`, `needs_input`, `limit`, `stalled`,
`ended`, or `unknown`. No source SHALL infer completion from missing evidence.

#### Scenario: A benign status banner does not cause a false positive

- **WHEN** a Claude session's pane shows only the `Auto-update failed: no
  write permission to npm prefix` notice while background shells are running
- **AND** `watch` classifies that session
- **THEN** the classified state is `waiting_background`
- **AND** it is never `unknown` or treated as requiring attention

#### Scenario: A gone session is reported as ended

- **WHEN** a named session's tmux session no longer exists
- **AND** `watch` is asked about it
- **THEN** it reports `ended`

#### Scenario: Missing evidence stays unknown

- **WHEN** a Pi session has no event file, no herdr status and no adapter
- **THEN** `watch` reports `unknown`, not `idle`

#### Scenario: A later turn is not reported idle

- **WHEN** a Claude session's last recorded event is `turn_end` and it has started a new turn
- **THEN** a `turn_start` event classifies it `working`

#### Scenario: A lost turn-start hook does not pin idle

- **WHEN** a session's last event is `turn_end` and its pane adapter reports `working`
- **THEN** `watch` reports `working`

### Requirement: Watch emits one event per state transition, not a firehose

`scripts/nogg session watch` SHALL emit an event only when a session's
classified state changes from its previously reported state, plus a
`stalled` event when a session's pane and log are both unchanged for the
configured `--stall-after` duration while its last reported state was
`working`. It SHALL NOT emit a repeated event for an unchanged state on
every poll.

#### Scenario: A steady-state session produces no repeated events

- **WHEN** a session's classified state is unchanged across consecutive polls
- **THEN** `watch` emits no new event for that session on those polls

#### Scenario: A stalled working session is reported once

- **WHEN** a session's last reported state is `working` and its pane and log
  are unchanged for the configured `--stall-after` duration
- **THEN** `watch` emits exactly one `stalled` event
- **AND** it does not emit a repeated `stalled` event every subsequent poll
  for the same unchanged condition

### Requirement: A usage-limit hit is classified as `limit` with a resolved reset time

When a session's pane matches an adapter's usage-limit pattern, `watch` SHALL
classify its state as `limit` and SHALL carry an absolute, resolved ISO 8601
reset timestamp in the event, parsed from the stated time against the host's
current local date and rolled to the next day when the parsed time precedes
the current time.

#### Scenario: A same-day reset time resolves correctly

- **WHEN** a session's pane states a usage-limit reset time later the same
  day
- **THEN** the `limit` event carries that time resolved to today's date

#### Scenario: An overnight reset time rolls to the next day

- **WHEN** a session's pane states a usage-limit reset time earlier than the
  current time of day
- **THEN** the `limit` event's resolved timestamp is on the following day,
  not the current one

### Requirement: Resume-when-ready waits out a limit and resumes without switching models

`scripts/nogg session resume-when-ready <name>` SHALL wait until the named
session's `watch`-classified state is no longer `limit`, using that state's
resolved reset timestamp rather than a tight poll loop. If a model-switch
prompt remains on screen once the limit clears, it SHALL dismiss it by
keeping the current model, never by switching. It SHALL then send a resume
instruction to the session.

#### Scenario: The session resumes automatically once the limit clears

- **WHEN** a session is in the `limit` state with a resolved reset timestamp
- **AND** `resume-when-ready` is running for it
- **THEN** once the reset timestamp passes and the session's state is no
  longer `limit`, a resume instruction is sent to the session with no
  operator action required

#### Scenario: A residual model-switch prompt is dismissed without switching

- **WHEN** the limit clears and a "switch model?" prompt remains on screen
- **THEN** `resume-when-ready` dismisses it while keeping the current model

### Requirement: Send verifies a message was actually submitted

`session send` SHALL verify submission by default for Claude, Codex and
Antigravity, including calls from kickoff and nudge. `--verify` SHALL remain
accepted and SHALL retain its explicit-verification meaning for other agents.
Success SHALL require evidence of this operation's message being submitted;
transport success alone and an already-working agent SHALL NOT suffice.

Pane delivery SHALL refuse existing actual input or an unidentifiable
composer before typing, directing the operator to explicit replacement with
`nudge --message`. It SHALL NOT silently merge or erase operator input.
Nudge SHALL retain its independently specified bounded replacement checks.
After typing, delivery SHALL allow processing time before one Enter. It
SHALL retry Enter at most once and only while the operation's message is
positively pending. It SHALL NOT retry by typing the message again.
Unknown evidence or exhausted waits SHALL fail non-zero without printing a
successful send, nudge or kickoff confirmation.

#### Scenario: An unsubmitted message is retried

- **WHEN** the operation's message remains positively pending after the initial Enter
- **THEN** submission is retried once after the configured processing interval
- **AND** a still-pending or unverified message fails non-zero

#### Scenario: Ordinary Claude send verifies without a flag

- **WHEN** plain `session send` targets Claude and the message remains in its composer
- **THEN** it performs bounded verification without requiring `--verify`
- **AND** it does not print success merely because text and keys were sent

#### Scenario: Existing operator input is preserved

- **WHEN** ordinary pane send finds unrelated actual input or an unknown composer
- **THEN** it refuses before typing or sending Enter and points to `nudge --message`

#### Scenario: A prior working state is not a receipt

- **WHEN** an agent was already working before the message was sent
- **THEN** that unchanged state alone cannot confirm the new message

### Requirement: Watch classifies an idle Claude session stuck in manual mode distinctly

For a Claude session, `classify()` SHALL report `awaiting_manual_approval`
instead of `idle` when the pane is otherwise idle and its permission-mode
status line reads `⏸ manual mode on`. This state SHALL NOT apply to Codex
sessions, which have no equivalent status line.

#### Scenario: An idle manual-mode session is distinguished from plain idle

- **WHEN** a Claude session's pane shows an empty prompt and `⏸ manual mode
  on` in its status line
- **THEN** `classify()` reports `awaiting_manual_approval`, not `idle`

#### Scenario: A working or auto-mode session is unaffected

- **WHEN** a Claude session's pane shows `⏵⏵ auto mode on` or is otherwise
  classified `working`
- **THEN** `classify()` reports that state as before; `awaiting_manual_approval`
  never overrides a non-idle classification

### Requirement: `session launch` warns when a lead or specialist session will not act unattended

`scripts/nogg session launch` SHALL print a one-line warning to the
launching terminal when `--role lead` or `--role specialist:*` is launched
with none of `--profile`, `--prompt`, or `--full-access` given. The warning
SHALL name the session and state that it will not act without a human
attached. `--role orchestrator` SHALL never trigger this warning.

#### Scenario: A bare lead launch warns

- **WHEN** `session launch --role lead --bead <id>` runs with no `--profile`,
  `--prompt`, or `--full-access`
- **THEN** the launch output includes a warning naming the session and the
  restricted/manual-mode consequence

#### Scenario: An explicit profile suppresses the warning

- **WHEN** `session launch --role lead --bead <id> --full-access` runs
- **THEN** no such warning is printed

#### Scenario: Orchestrator launches are unaffected

- **WHEN** `session launch --role orchestrator` runs
- **THEN** no such warning is printed, regardless of profile arguments

### Requirement: `session launch` names the missing kickoff step, and `session kickoff` delivers it

Bare `session launch` SHALL name the missing first message and exact kickoff
command without sending anything. `session kickoff <name> [--message TEXT]`
SHALL wait for positively established startup readiness and deliver one
verified first instruction. With `--message` it SHALL use that exact text;
otherwise it SHALL compose from the recorded scope. Lead messages SHALL
name the authorized Bead and change; specialist messages SHALL name the
already-claimed Bead and forbid Main Worker mutations; planning messages
SHALL name the planning identifier and dedicated worktree and require that
session to acquire its own planning lock before spec writes.

Kickoff SHALL refuse non-running sessions and execution sessions without a
Bead when no explicit message is supplied. `launch --kickoff` SHALL chain
the same readiness and verification path and propagate its failure.
Waiting SHALL be bounded and configurable. A startup timeout, trust or
permission dialog, limit, failed session or unknown readiness SHALL never
cause speculative input or automatic dialogue acceptance. Diagnostics SHALL
name the session, missing evidence and the next operator action.
Concurrent or repeated attempts to deliver the same kickoff SHALL NOT
duplicate a confirmed or ambiguously accepted instruction.

#### Scenario: A bare launch names the missing step

- **WHEN** launch runs without `--kickoff`
- **THEN** it names the exact kickoff command and sends no first message

#### Scenario: Kickoff composes the expected message

- **WHEN** a running Lead is ready and kickoff has no explicit message
- **THEN** its authorized Bead and change instruction is sent and confirmed submitted

#### Scenario: Kickoff refuses on a non-running session

- **WHEN** kickoff targets a non-running session
- **THEN** it refuses with no keys or queue request

#### Scenario: Kickoff refuses with no message and no Bead

- **WHEN** an execution session has no Bead and no explicit message is supplied
- **THEN** kickoff refuses with no delivery attempt

#### Scenario: `--kickoff` chains automatically

- **WHEN** launch is given `--kickoff`
- **THEN** it returns success only after the readiness and verified kickoff path succeeds

#### Scenario: Planning kickoff needs no placeholder Bead

- **WHEN** a ready planning session has its recorded identifier and dedicated worktree
- **THEN** its instruction requires its own planning lock without claiming execution work

#### Scenario: Specialist kickoff respects delegation authority

- **WHEN** a ready specialist is assigned one already-claimed Bead
- **THEN** kickoff forbids claiming, re-statusing, closing, committing or selecting sibling work

#### Scenario: Claude starts slowly

- **WHEN** a live Claude session has not yet rendered a ready input box
- **THEN** kickoff waits within its deadline and types nothing before readiness

#### Scenario: Antigravity readiness arrives after thirty seconds

- **WHEN** the current startup turn finishes after thirty seconds but before the configured deadline
- **THEN** kickoff waits and sends the instruction once without requiring an operator retry

#### Scenario: Antigravity is idle without a Stop readiness event

- **WHEN** the exact live Antigravity process repeatedly reports idle or done with a positively empty composer
- **AND** no permission, trust, limit or working indication contradicts readiness
- **THEN** kickoff can establish readiness without inventing a conversation ID or bypassing hooks

#### Scenario: Readiness times out

- **WHEN** neither valid current hook evidence nor reliable live readiness appears before the deadline
- **THEN** kickoff fails with a readiness diagnostic and no input or queue request

#### Scenario: Repeated kickoff after ambiguous queue acceptance

- **WHEN** the same kickoff was accepted by the transport but its submission could not be confirmed
- **THEN** a repeated kickoff checks existing evidence and does not enqueue or type it again

### Requirement: `session nudge` reliably submits a pane regardless of prior input

Session nudge SHALL refuse non-running sessions. With --message it SHALL deliberately replace actual pending input and submit the supplied text with bounded verification. Without --message it SHALL resend only positively identified actual input; placeholder suggestions and ambiguous pane text SHALL never be executed and SHALL produce a no-op or request for an explicit message.

#### Scenario: Placeholder-only prompt

- **WHEN** an idle pane displays only a suggested next instruction and nudge has no message
- **THEN** nothing is submitted and the operator is told to provide an explicit message

#### Scenario: Explicit replacement

- **WHEN** nudge receives --message for a running session
- **THEN** the supplied message replaces actual prior input and is verified submitted

#### Scenario: Non-running session

- **WHEN** nudge targets a stopped session
- **THEN** no keys or message are sent

#### Scenario: A stale pre-filled suggestion is resubmitted

- **WHEN** a pane shows a stale suggested placeholder and the operator supplies that instruction explicitly with --message
- **THEN** the supplied instruction is submitted; the suggestion alone is never automatically executed

#### Scenario: An explicit message overrides stale pane content

- **WHEN** nudge receives --message and the session has unrelated actual buffered input
- **THEN** the explicit message replaces the actual input and is verified submitted

#### Scenario: Nudging an empty pane is a reported no-op

- **WHEN** nudge has no message and no actual buffered input can be positively identified
- **THEN** no text is submitted and the command reports that an explicit message is needed

#### Scenario: Nudging a non-running session is refused

- **WHEN** nudge targets a non-running session
- **THEN** it refuses without sending input

### Requirement: `send --verify` detects an unsubmitted Claude message, not only Codex

`scripts/nogg session send <name> "<message>" --verify`'s retry-on-
unsubmitted check SHALL detect pending input for a Claude session using the
same pane-reading mechanism `session nudge` uses, not only for Codex
sessions.

#### Scenario: A Claude send retries when left unsubmitted

- **WHEN** `session send <name> "..." --verify` runs against a Claude
  session
- **AND** the pane afterward shows that message still sitting unsubmitted
- **THEN** `send` retries the submit step once, exactly as it already does
  for Codex

### Requirement: `session sweep` reports whether a running session's own work still needs it

Session sweep SHALL distinguish change-complete, bead-blocked and active for the session authorized scope, and SHALL expose unknown evidence rather than inventing completion. A blocked unrelated sibling SHALL NOT block runnable assigned work. Completion SHALL require mapped work closed and merged PR or explicit integration evidence; open or unknown integration status SHALL prevent completion. Sweep SHALL show idle duration and input certainty separately and SHALL NOT stop, nudge or claim work.

#### Scenario: Unrelated blocked sibling

- **WHEN** the assigned task is runnable while a sibling outside its dependency cone is blocked
- **THEN** the session is not classified bead-blocked solely because of that sibling

#### Scenario: Integrated complete scope

- **WHEN** all authorized mapped work is closed and integration is evidenced
- **THEN** the session is classified change-complete

#### Scenario: Unknown PR

- **WHEN** PR lookup or cached integration evidence is unavailable
- **THEN** the session is not marked complete and unknown evidence is visible

#### Scenario: A session whose change is fully merged is flagged complete

- **WHEN** every mapped Bead in the authorized change is closed and its PR is verified merged
- **THEN** sweep reports change-complete

#### Scenario: A session correctly self-blocked is flagged, not hidden

- **WHEN** its own assigned Bead or an unmet dependency in its authorized scope is blocked
- **THEN** sweep reports bead-blocked with the blocking Bead ID; an unrelated sibling alone does not qualify

#### Scenario: A genuinely active session is reported as active

- **WHEN** assigned work is runnable and completion or blocking evidence does not apply
- **THEN** sweep reports active with separate idle/input evidence

### Requirement: `doctor` surfaces flagged sessions without a per-session manual audit

`scripts/nogg doctor` SHALL report one `NOTE` per currently running session
classified `awaiting_manual_approval`, `change-complete`, or `bead-blocked`,
naming the session and the reason, using the same detection `session sweep`
performs.

#### Scenario: A flagged session appears in one doctor pass

- **WHEN** one or more running sessions are `change-complete`,
  `bead-blocked`, or `awaiting_manual_approval`
- **AND** an operator runs `scripts/nogg doctor`
- **THEN** its output includes one `NOTE` per such session, naming it and
  the reason, without a separate `tmux capture-pane` per session

### Requirement: CI observations are explicit and bounded

Session sweep --checks SHALL expose PR head/check fingerprints and whether they have been explicitly acknowledged. Doctor SHALL use cached evidence without mandatory remote calls. New or changed checks SHALL remain unchecked until an explicit checks-ack observation; missing/stale/network-failed evidence SHALL be visible as unknown.

#### Scenario: New failed checks

- **WHEN** a PR check fingerprint changes after its last acknowledgement
- **THEN** sweep --checks reports the failure as unchecked and doctor can show the cached result

#### Scenario: Read-only inspection

- **WHEN** sweep observes checks without checks-ack
- **THEN** the observation is not silently acknowledged

### Requirement: Stale hook state cannot pin a resolved permission prompt

Structured session events SHALL be reconciled with current live evidence when the last needs_input event is stale or contradicted by a resolved prompt. A missing Stop event SHALL NOT indefinitely override a reliable live idle/working classification; fresh active prompts SHALL remain needs_input.

#### Scenario: Denied tool without Stop

- **WHEN** a needs_input event remains but the live pane shows the prompt resolved
- **THEN** watch reports current live state rather than permanently needs_input

### Requirement: Submit verification is agent-specific for Codex and Antigravity

Ordinary send, `send --verify`, `nudge --message` and kickoff SHALL use the
target agent's own evidence. They SHALL never infer pending input from the
last visible screen line or report success without established delivery.

For Codex:

- Queue delivery SHALL remain the primary route when the exact thread
  resolves. Queue acceptance SHALL NOT alone count as submission.
- Fresh submitted-user-message evidence for that thread and this operation
  SHALL confirm queue delivery even when the composer cannot be identified.
  Historical matching text or evidence from another thread SHALL NOT count.
- If the queue leaves this operation's exact text positively pending, a
  bounded Enter sequence SHALL recover it without typing the text again.
- No receipt with an empty or unknown composer SHALL fail as unverified;
  it SHALL NOT cause a second queue request or pane text fallback.
- Pane fallback SHALL be allowed only before queue acceptance, when the
  queue was not invoked or definitively refused without acceptance.
- A pending pane message after one retry SHALL fail as unsubmitted.

For Antigravity:

- The classifier SHALL read only the framed composer and ignore its
  permanent status bar and lines below the frame.
- After explicit pane delivery, an observed transition to backend working
  or done, or a known composer holding this message becoming empty or a
  placeholder, SHALL confirm submission. An already-working backend alone
  SHALL NOT confirm it.

Only positively identified pending input belonging to this operation SHALL
receive a retry Enter. Unknown or unrelated input SHALL receive none.

#### Scenario: A Codex message nudge does not report a false success

- **WHEN** Codex pane fallback leaves the message pending after one retry
- **THEN** nudge fails as unsubmitted and prints no success

#### Scenario: A Codex message nudge uses the queue

- **WHEN** the exact Codex thread resolves and fresh evidence confirms its queued message
- **THEN** nudge succeeds through the queue with no pane text injection

#### Scenario: Queue acceptance leaves the text in the composer

- **WHEN** queue exits zero but its exact message remains pending
- **THEN** Nogging submits that buffer with at most one retry and does not retype or requeue it

#### Scenario: Queue accepts but delivery remains unproven

- **WHEN** queue exits zero and no matching fresh receipt or identifiable pending message appears
- **THEN** the operation fails as unverified without falling back to typing or sending another Enter

#### Scenario: Old or foreign text is not delivery evidence

- **WHEN** a transcript contains the same text before this operation or in a different thread
- **THEN** that text does not confirm the operation

#### Scenario: Antigravity's status bar is not pending input

- **WHEN** a delivered message leaves an empty framed composer above a permanent status bar
- **THEN** verification succeeds without another Enter

### Requirement: Claude's Layer-2 hooks run from any working directory

The effective settings written for a launched Claude session SHALL register the
`UserPromptSubmit` (`turn_start`), `Stop` (`turn_end`), `Notification` (`needs_input`),
`StopFailure` (`turn_error`) and `SessionEnd` (`session_end`) hooks with an absolute,
shell-quoted path to the launching checkout's `scripts/nogg`, resolved when the
settings are written. No generated hook
command SHALL depend on the session's current working directory, so a `cd` into a
subdirectory does not lose events. `SubagentStop` SHALL NOT be wired.

#### Scenario: Generated hook commands are absolute

- **WHEN** `session launch --agent claude` writes the effective settings
- **THEN** every generated hook command begins with an absolute quoted `scripts/nogg` path
- **AND** no generated hook command begins with a relative `scripts/` path

#### Scenario: A hook fires after the agent changes directory

- **WHEN** the `Stop` hook command runs with a subdirectory of the checkout as its working directory
- **THEN** it resolves `scripts/nogg` and records the `turn_end` event for the session

#### Scenario: A path with spaces is quoted

- **WHEN** the launching checkout path contains a space
- **THEN** the generated hook commands remain valid shell and resolve correctly

### Requirement: Delivery waits and evidence collection are bounded and private

Delivery SHALL use finite validated processing, startup and verification
timeouts. Invalid values SHALL refuse before message injection. Evidence
collection SHALL read only the exact target's local session evidence within
bounded work and SHALL persist no transcript content or credentials.
Unknown runtime evidence SHALL remain unknown. The operator SHALL be told
when a transport accepted a message whose submission remains unproven, so
that it is not blindly resent.

#### Scenario: Invalid timing configuration

- **WHEN** a delay is negative, non-finite, boolean or not numeric
- **THEN** the operation refuses before queueing, typing or sending keys

#### Scenario: Unavailable transcript

- **WHEN** the target's transcript is missing, unreadable, replaced or unsupported
- **THEN** Nogging uses only other positively established evidence or fails as unverified
- **AND** it does not scan unrelated conversations or store their contents

### Requirement: Every focus runtime reports its lifecycle in one normalized form

Claude Code, Codex and Pi sessions SHALL report through one normalized event
schema with the events `turn_start`, `turn_end`, `needs_input`, `turn_error`,
`session_end`, `blocked` and `done`. `session emit` SHALL read at most 64 KiB of
hook JSON from stdin when present, SHALL tolerate invalid input, and SHALL keep only
a whitelist of fields: `source`, `error`, `notification_type`, the count of
`background_tasks`, and an excerpt of the last agent message. An excerpt SHALL be at
most 300 characters, single-line, with control characters removed, and redacted of
secrets and email addresses. The per-session events file SHALL be rotated at 256 KiB.

A `Notification` SHALL map to `needs_input` only for a question type:
`permission_prompt`, `elicitation_dialog`, `elicitation_url_dialog` or
`agent_needs_input`. `turn_error` with `rate_limit` SHALL classify as `limit`. A
`turn_end` with background tasks in flight SHALL classify as `waiting_background`.
Antigravity's existing Stop event path SHALL be unchanged.

#### Scenario: An idle notification is not a question

- **WHEN** Claude sends a `Notification` of type `idle_prompt`
- **THEN** no `needs_input` event is recorded

#### Scenario: A paused session is not finished

- **WHEN** Claude's `Stop` input lists a running background task
- **THEN** the session classifies `waiting_background`

#### Scenario: Hook input cannot leak through the event file

- **WHEN** a hook payload contains a secret in the last message and unknown fields
- **THEN** the recorded event holds a redacted excerpt and none of the unknown fields

#### Scenario: A malformed payload still records the event

- **WHEN** stdin holds invalid JSON
- **THEN** the event is recorded without optional fields and the command exits 0

### Requirement: A supervised Pi session reports its lifecycle

A supervised Pi session SHALL load `.pi/extensions/nogging-lifecycle.ts`, exactly once
per session, which does nothing unless `NOGG_SESSION_NAME` is set. It SHALL emit
`turn_start` on `agent_start`, `turn_end` on `agent_settled` and never on `agent_end`,
`needs_input` on `ui_prompt_start`, clear it on `ui_prompt_end`, emit `turn_error` when
`agent_before_settle` reports `outcome: "error"`, and emit `session_end` on
`session_shutdown`. Handler errors SHALL NOT affect the session, and its child
processes SHALL be bounded by a timeout and shall not delay Pi's exit.

#### Scenario: A retried run is not reported finished

- **WHEN** Pi fires `agent_end` and then starts an automatic retry
- **THEN** no `turn_end` is emitted until `agent_settled`

#### Scenario: Pi is classified in watch

- **WHEN** `session watch` runs for a supervised Pi session on tmux whose last event is `turn_end`
- **THEN** it reports `idle`, not `unknown`

#### Scenario: Outside a supervised session it does nothing

- **WHEN** Pi loads the extension with `NOGG_SESSION_NAME` unset
- **THEN** it registers no behaviour and emits nothing

### Requirement: Codex turns are observed from the rollout without an install

For a Codex session, a turn's start and end SHALL be read from the session's own
rollout through a bounded reader, resolved by the session's exact thread identity and
never by a guess. `task_complete` SHALL yield `turn_end` with an excerpt of
`last_agent_message`, and a terminal abort SHALL yield `turn_end` with the reason. An
unrecognized or unreadable record SHALL leave the state to the next evidence source.

#### Scenario: A finished Codex turn needs no hook

- **WHEN** a supervised Codex session has no user-level hook and its rollout ends with `task_complete`
- **THEN** it classifies `idle` and exposes the excerpt

#### Scenario: An unknown rollout is not read as finished

- **WHEN** the rollout has only unrecognized records
- **THEN** classification falls through to herdr or the pane adapter

### Requirement: The Codex stop hook is an explicit, user-level install

`nogg session-hooks install --agent codex` SHALL merge one `Stop` entry into the
user-level `~/.codex/hooks.json`, preserving every other entry, and SHALL record its
trust through Codex's own configuration API, printing what it trusted. The hook's
command SHALL be constant across repositories and SHALL do nothing outside a
supervised session. `remove` SHALL reverse both. `status` SHALL report `trusted`,
`untrusted`, `modified` or `missing` from Codex's own `hooks/list`. `init` and `update`
SHALL NOT perform this install. `session-launch` SHALL NOT pass
`--dangerously-bypass-hook-trust`, because Codex runs a local hook outside its sandbox
and a sandboxed session can write its own project `.codex/hooks.json`.

#### Scenario: A foreign hook survives the install

- **WHEN** `~/.codex/hooks.json` holds another tool's `SessionStart` entry
- **THEN** the install leaves it byte-equivalent and adds only the Nogging `Stop` entry

#### Scenario: The hook is inert outside Nogging

- **WHEN** a bare Codex session ends a turn with the hook installed
- **THEN** the hook exits 0 and records nothing

#### Scenario: A modified hook is reported

- **WHEN** the hook definition no longer matches its trusted hash
- **THEN** `status` and `doctor` report `modified` and name the fix, and neither fails

#### Scenario: A launch never bypasses trust

- **WHEN** any Codex session launches
- **THEN** its argv does not contain `--dangerously-bypass-hook-trust`

### Requirement: A Lead ends its work with an explicit signal

`nogg session signal blocked|done "<reason>"` SHALL append the matching event for the
calling supervised session. It SHALL need neither network nor Dolt, SHALL refuse
outside a supervised session, and SHALL limit the reason to 300 characters with the
excerpt rules. It SHALL print whether dispatch is on and what the Lead should do next.
A signal SHALL NOT change the classified state, so callers that test for `idle` keep
working, and `session watch` SHALL report it as its own event. The restricted launch
profile SHALL allow the command.

#### Scenario: A sandboxed Lead can signal

- **WHEN** a restricted Codex Lead with no Dolt access runs `session signal blocked "..."`
- **THEN** the event is recorded and the command exits 0

#### Scenario: A signal does not break delivery

- **WHEN** a Lead that signalled `done` is idle
- **THEN** it classifies `idle` and `session send` still works

### Requirement: A bounded stop guard keeps a Lead from ending with work left

`nogg session completion-check [--json]` SHALL report the gaps `dirty`, `unpushed` and
`no-signal` from local git facts and the session's events, and SHALL exit 0 on an
internal error. For a `lead` session under the `autonomous` prompt, on Claude Code,
Codex and Pi, a stop with gaps SHALL be turned into one continuation with a fixed
message: `decision: "block"` on Claude's and Codex's `Stop` hook, and `continue: true`
with a `custom_message` on Pi's `agent_before_settle`. The guard SHALL pass when
`stop_hook_active` is true, and on Pi after one continuation per user input. It SHALL
NOT apply when a `blocked` or `done` signal is newer than the last `turn_start`, when
background tasks are in flight, or after an API error. A continued stop SHALL be
recorded as `guard_continue`, not `turn_end`. Any guard failure SHALL allow the stop.

#### Scenario: Uncommitted work gets one continuation

- **WHEN** an autonomous Lead ends its turn with a dirty tree
- **THEN** it continues once with the fixed message naming the gap

#### Scenario: The guard cannot loop

- **WHEN** the Lead stops again with `stop_hook_active` true
- **THEN** the stop is allowed

#### Scenario: A blocked Lead may stop

- **WHEN** a Lead signals `blocked` and then ends its turn with a dirty tree
- **THEN** the stop is allowed

#### Scenario: A broken check never traps a session

- **WHEN** `completion-check` raises or times out
- **THEN** the stop is allowed

### Requirement: Runtime capabilities are explicit

`nogg session capabilities [--agent <agent>] [--profile <profile>] [--json]` SHALL
report, from what launch resolves and not from a separate hand-kept list, whether a
session of that agent and authority can launch child sessions, reach Dolt, push, open
a pull request, rebase without an operator, and run in-process specialists. An answer
that cannot be established SHALL read `unknown`. A `session launch` from a caller that
cannot write the required state SHALL refuse before side effects with a message that
names the reason and tells the caller to signal blocked, instead of surfacing a raw
filesystem error. No authority SHALL be widened.

#### Scenario: A sandboxed launch fails clearly

- **WHEN** a sandboxed Codex Lead runs `session launch` and the usage reservation path is read-only
- **THEN** it refuses with the named reason and creates no session, record or log

#### Scenario: A kickoff can be checked first

- **WHEN** the orchestrator runs `session capabilities --agent codex --profile trusted --json`
- **THEN** the output states whether that Lead can launch a reviewer session
