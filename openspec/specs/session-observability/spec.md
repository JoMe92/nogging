# session-observability Specification

## Purpose

Defines observable agent activity, operator input delivery and usage-limit recovery for supervised Nogging sessions.

## Requirements

### Requirement: Watch classifies a session's live state via a per-agent adapter

`scripts/nogg session watch` SHALL classify each named or running session's
current state using an adapter keyed off that session's recorded `agent`
field, never a single global keyword match. Classification SHALL strip
lines matching the adapter's `ignore` patterns before checking state, and
SHALL consider only the pane's last approximately 15 lines, not its full
scrollback. The classified state SHALL be one of `working`,
`waiting_background`, `idle`, `needs_input`, `limit`, `stalled`, `ended`, or
`unknown`.

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

`scripts/nogg session send <name> "<message>" --verify` SHALL confirm, after
sending, that the message was submitted rather than left sitting unsent in
the session's input box, and SHALL retry the submit step once if it was not.

#### Scenario: An unsubmitted message is retried

- **WHEN** a message is sent to a session with `--verify`
- **AND** the pane afterward shows the message still sitting unsubmitted in
  the input box
- **THEN** `send` retries the submit step once before returning

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

`scripts/nogg session launch`'s success output SHALL name the fact that the
session will not act until it receives a first message, and the exact
follow-up command, whenever `--kickoff` was not passed. `scripts/nogg session
kickoff <name> [--message TEXT]` SHALL deliver that first message: with
`--message`, that exact text; without it, a role-specific message composed from its recorded scope. A Lead message names its Bead and change and directs only authorized work; a specialist message names its already-claimed Bead and forbids claiming, committing or closing; a planning message names its planning identifier and dedicated worktree and directs acquisition of its own planning lock before spec writes. `session kickoff` SHALL refuse, sending
nothing, when the named session is not `running`, or when no `--message` is
given and an execution-role session record carries no `bead_id`. `--kickoff` on `session
launch` SHALL chain a `session kickoff` call immediately after a successful
launch.

#### Scenario: A bare launch names the missing step

- **WHEN** `session launch --role lead --bead <id>` runs with no `--kickoff`
- **THEN** its output includes a line naming the missing kickoff step and
  the exact command to run

#### Scenario: Kickoff composes the expected message

- **WHEN** `session kickoff <name>` runs with no `--message` for a `running`
  Lead session whose record carries a `bead_id`
- **THEN** a message naming that Bead ID and its change is sent to the
  session and is confirmed submitted

#### Scenario: Kickoff refuses on a non-running session

- **WHEN** `session kickoff <name>` runs for a session that is not `running`
- **THEN** it refuses with a clear error and sends nothing

#### Scenario: Kickoff refuses with no message and no Bead

- **WHEN** `session kickoff <name>` runs with no `--message` for a `running`
  execution-role session whose record carries no `bead_id`
- **THEN** it refuses with a clear error and sends nothing

#### Scenario: `--kickoff` chains automatically

- **WHEN** `session launch --role lead --bead <id> --kickoff` runs
- **THEN** the resulting session has already received its first message by
  the time the command returns

#### Scenario: Planning kickoff needs no placeholder Bead

- **WHEN** kickoff targets a running planning session with a valid planning identifier and dedicated worktree
- **THEN** it sends a planning instruction directing that session to acquire its own lock without selecting or claiming any Bead

#### Scenario: Specialist kickoff respects delegation authority

- **WHEN** kickoff targets a running specialist assigned one already-claimed Bead
- **THEN** it directs only that Bead work and does not authorize claiming, committing, closing or selecting sibling tasks

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

`session nudge --message` and `session send --verify` SHALL verify a Codex or
Antigravity submission with that agent's own input classifier. They SHALL
never decide it from the last visible screen line. They SHALL report success
only when delivery is positively established, and they SHALL fail as
unverified rather than report success when it is not.

For Codex:

- A `--message` nudge SHALL deliver through `codex queue`, the same path
  `session send` uses, whenever the session's thread resolves.
- When it falls back to pane input, it SHALL verify through the Codex
  composer. Non-dim composer text is pending input; a dim suggestion is not.
- Pending input that still holds the sent text after one retry SHALL fail as
  unsubmitted.
- A composer that cannot be identified SHALL fail as unverified.

For Antigravity:

- The classifier SHALL read only the composer between the input frame's rule
  lines. It SHALL ignore the permanent status bar and every line below the
  frame.
- On herdr, an agent status of `working` or `done` observed after the submit
  SHALL count as submitted.

A submit SHALL be retried only while input is positively pending, so a
delivered message never receives an extra Enter.

#### Scenario: A Codex message nudge does not report a false success

- **WHEN** `session nudge <codex-session> --message "…"` falls back to pane input and the text stays in the Codex composer after one retry
- **THEN** the command fails as unsubmitted and does not print `nudged`

#### Scenario: A Codex message nudge uses the queue

- **WHEN** `session nudge <codex-session> --message "…"` runs and the session's Codex thread resolves
- **THEN** the message is delivered through `codex queue`, as `session send` delivers it

#### Scenario: Antigravity's status bar is not pending input

- **WHEN** an Antigravity message is delivered and the pane shows an empty composer above the permanent status bar
- **THEN** `send --verify` and `nudge --message` report success without an extra Enter

### Requirement: Claude's Layer-2 hooks run from any working directory

The effective settings written for a launched Claude session SHALL register the
`Stop` (`turn_end`) and `Notification` (`needs_input`) hooks with an absolute,
shell-quoted path to the launching checkout's `scripts/nogg`, resolved when the
settings are written. No generated hook command SHALL depend on the session's
current working directory, so a `cd` into a subdirectory does not lose events.

#### Scenario: Generated hook commands are absolute

- **WHEN** `session launch --agent claude` writes the effective settings
- **THEN** the `Stop` and `Notification` hook commands begin with an absolute quoted `scripts/nogg` path
- **AND** no generated hook command begins with a relative `scripts/` path

#### Scenario: A hook fires after the agent changes directory

- **WHEN** the `Stop` hook command runs with a subdirectory of the checkout as its working directory
- **THEN** it resolves `scripts/nogg` and records the `turn_end` event for the session

#### Scenario: A path with spaces is quoted

- **WHEN** the launching checkout path contains a space
- **THEN** the generated hook commands remain valid shell and resolve correctly
