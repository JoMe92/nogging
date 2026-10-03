## ADDED Requirements

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
