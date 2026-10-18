## MODIFIED Requirements

### Requirement: The tmux backend preserves existing behaviour

The tmux backend SHALL preserve the dedicated socket, new-session environment,
pane log, PID query, captures with and without attributes, kill-session and
read-only attach. Its text transport SHALL preserve supplied multiline text
as one paste when the application enables bracketed paste mode. Simultaneous
messages SHALL NOT exchange buffer contents, and temporary buffers SHALL be
removed after success or failure. Text transfer SHALL NOT itself send Enter;
submit timing, verification and any retry SHALL remain supervision policy
above the backend seam. Claude SHALL NOT receive an unconditional double Enter.

The dedicated tmux server SHALL remain shared by all checkouts and the
Orchestration Agent. Cleanup SHALL stop it only when the server's own listing
succeeds and reports no sessions. A failed listing SHALL count as not empty.
The fenced caller's no-server-start rule SHALL remain in force on every
transport command. No delivery failure SHALL kill or restart the server.

Existing tests SHALL remain green except assertions of intentionally changed
text transport or unconditional Enter counts and the corrected shared-server
stop rule.

#### Scenario: Existing tests stay green

- **WHEN** the new transport is used without herdr sessions
- **THEN** existing lifecycle tests pass with changes restricted to assertions of corrected behavior

#### Scenario: Cleanup keeps a shared server that hosts other sessions

- **WHEN** current-checkout cleanup finishes but another session remains on the server
- **THEN** no kill-server is issued

#### Scenario: A failed listing never stops the server

- **WHEN** cleanup cannot list the server's sessions
- **THEN** it does not stop the server

#### Scenario: An unsandboxed caller's tmux commands are unchanged

- **WHEN** a caller outside the execution sandbox performs a tmux lifecycle, capture or attach operation
- **THEN** its argv remains byte-identical to the previous behavior
- **AND** only text transfer uses the explicitly changed paste transport specified here

#### Scenario: Parallel multiline pastes are isolated

- **WHEN** two sessions receive different multiline messages concurrently
- **THEN** each receives only its own text with line breaks preserved and paste boundaries when enabled
- **AND** no temporary paste buffer remains

#### Scenario: Paste fails

- **WHEN** loading or pasting a message fails
- **THEN** no submission key is sent, temporary resources are cleaned up and the error propagates
- **AND** the shared server remains untouched

### Requirement: Nudge and send verification degrade safely without screen attributes

Nudge and send policy SHALL be identical on both backends. When capture keeps
SGR attributes, placeholder detection SHALL behave as on tmux. Without
attributes, a Claude box containing text SHALL classify as unknown, never
as inferred operator input or a suggestion. Nudge without `--message` SHALL
submit nothing and ask for an explicit message.

For an explicit message, a known safe baseline and the operation's own text
injection SHALL establish ownership before submit. A transition from a box
known to hold that message to an empty box, or an observed new backend
working/done transition after submit, SHALL count as delivery. An unknown
box, a different nonempty box, or an unchanged baseline working status alone
SHALL NOT count. A single retry SHALL be permitted only when the known box
still holds the operation's text; otherwise the operation SHALL fail as
unverified without speculative keys.

#### Scenario: A placeholder is never executed without attributes

- **WHEN** a herdr Claude pane has no attributes and nudge has no explicit message
- **THEN** no input is submitted and the operator is told to pass `--message`

#### Scenario: An explicit message is verified by the replacement check

- **WHEN** an explicit message is typed from a known empty baseline on herdr
- **AND** the backend transitions to working after submit
- **THEN** delivery is verified without an extra Enter

#### Scenario: Changed nonempty text is not a receipt

- **WHEN** the box changes to unrelated nonempty text after submit
- **THEN** that change alone establishes no success and causes no speculative Enter
