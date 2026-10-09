# session-observability Specification

## Purpose
TBD - created by archiving change session-observability. Update Purpose after archive.

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
`--message`, that exact text; without it, a message composed from the
session's own `bead_id` and the Bead's `openspec:change:` label, naming both
and directing the session to claim the Bead and proceed through that
change's `tasks.md` in order. `session kickoff` SHALL refuse, sending
nothing, when the named session is not `running`, or when no `--message` is
given and the session record carries no `bead_id`. `--kickoff` on `session
launch` SHALL chain a `session kickoff` call immediately after a successful
launch.

#### Scenario: A bare launch names the missing step

- **WHEN** `session launch --role lead --bead <id>` runs with no `--kickoff`
- **THEN** its output includes a line naming the missing kickoff step and
  the exact command to run

#### Scenario: Kickoff composes the expected message

- **WHEN** `session kickoff <name>` runs with no `--message` for a `running`
  session whose record carries a `bead_id`
- **THEN** a message naming that Bead ID and its change is sent to the
  session and is confirmed submitted

#### Scenario: Kickoff refuses on a non-running session

- **WHEN** `session kickoff <name>` runs for a session that is not `running`
- **THEN** it refuses with a clear error and sends nothing

#### Scenario: Kickoff refuses with no message and no Bead

- **WHEN** `session kickoff <name>` runs with no `--message` for a `running`
  session whose record carries no `bead_id`
- **THEN** it refuses with a clear error and sends nothing

#### Scenario: `--kickoff` chains automatically

- **WHEN** `session launch --role lead --bead <id> --kickoff` runs
- **THEN** the resulting session has already received its first message by
  the time the command returns

### Requirement: `session nudge` reliably submits a pane regardless of prior input

`scripts/nogg session nudge <name> [--message TEXT]` SHALL clear the
session's pane input line before sending anything. With `--message`, it
SHALL send that text after clearing. With no `--message`, it SHALL read the
pane's pending input text before clearing and resend exactly that text; if
the pane had no pending text, it SHALL send nothing further and report that
there was nothing to nudge. `session nudge` SHALL refuse, sending nothing,
when the named session is not `running`.

#### Scenario: A stale pre-filled suggestion is resubmitted

- **WHEN** a session's pane has non-empty, unsent text at its prompt
- **AND** `session nudge <name>` runs with no `--message`
- **THEN** the pane is cleared and that same text is resent and confirmed
  submitted

#### Scenario: An explicit message overrides stale pane content

- **WHEN** a session's pane has unrelated unsent text at its prompt
- **AND** `session nudge <name> --message "..."` runs
- **THEN** the pane is cleared first, then the given message is sent and
  confirmed submitted

#### Scenario: Nudging an empty pane is a reported no-op

- **WHEN** a session's pane prompt is empty
- **AND** `session nudge <name>` runs with no `--message`
- **THEN** nothing is sent and the command reports there was nothing to
  nudge

#### Scenario: Nudging a non-running session is refused

- **WHEN** `session nudge <name>` runs for a session that is not `running`
- **THEN** it refuses with a clear error and sends nothing

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

`scripts/nogg session sweep` SHALL report, for every `running` session with
a `bead_id`, one of `change-complete` (every Bead materialized under the
Bead's `openspec:change:` label is `closed`, and any pull request for the
session's worktree branch is `MERGED`), `bead-blocked` (the session's own
Bead or another Bead under the same label is `blocked`, naming the blocking
Bead), or `active` (neither). Each reported line SHALL also show whether the
pane currently has unsubmitted pending input and an idle-duration figure
derived from the session's worktree and log activity. `session sweep` SHALL
NOT stop, nudge, or otherwise change any session or Bead.

#### Scenario: A session whose change is fully merged is flagged complete

- **WHEN** every Bead under a running session's `openspec:change:` label is
  `closed` and that session's worktree branch has a `MERGED` pull request
- **THEN** `session sweep` reports that session as `change-complete`

#### Scenario: A session correctly self-blocked is flagged, not hidden

- **WHEN** a running session's own Bead, or a sibling Bead under the same
  change, is `status: blocked`
- **THEN** `session sweep` reports that session as `bead-blocked`, naming
  the blocking Bead

#### Scenario: A genuinely active session is reported as active

- **WHEN** a running session's assigned change has open, unblocked Beads and
  none of the above conditions hold
- **THEN** `session sweep` reports that session as `active`

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
