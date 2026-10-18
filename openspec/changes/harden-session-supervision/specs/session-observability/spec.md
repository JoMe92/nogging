## MODIFIED Requirements

### Requirement: `session nudge` reliably submits a pane regardless of prior input

Session nudge SHALL refuse non-running sessions. With --message it SHALL deliberately replace actual pending input and submit the supplied text with bounded verification. Without --message it SHALL resend only positively identified actual input; placeholder suggestions and ambiguous pane text SHALL never be executed and SHALL produce a no-op or request for an explicit message.

For an agent whose composer Nogging can classify (Claude, Codex when its message is typed into the pane, and Antigravity), the replacement SHALL hold on both session backends, including for pending input that wraps over several rows:

- Before typing, nudge SHALL clear the pending input with a bounded sequence of clearing keys and SHALL confirm from the screen that the composer is empty or shows only a placeholder. If it cannot confirm this, it SHALL fail without typing or submitting anything.
- After typing, nudge SHALL submit only when the composer holds exactly the supplied message, ignoring whitespace from wrapping. A composer that holds the message merged with other text SHALL never be submitted and SHALL never be reported as nudged; nudge SHALL clear it and fail.

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

#### Scenario: Wrapped pending input is replaced completely

- **WHEN** nudge receives --message for a Claude session on tmux or on herdr
- **AND** the composer holds actual pending input wrapped over two or more rows
- **THEN** every row of the pending input is cleared before the message is typed
- **AND** exactly the supplied message is submitted and verified

#### Scenario: Merged text is never submitted

- **WHEN** after typing, the composer holds the supplied message together with leftover input
- **THEN** no Enter is sent, the command does not report the session as nudged, and it exits non-zero

#### Scenario: Input that cannot be cleared is left untouched

- **WHEN** the bounded clearing sequence cannot bring the composer to empty or placeholder
- **THEN** the command exits non-zero, and no message text is typed and nothing is submitted
