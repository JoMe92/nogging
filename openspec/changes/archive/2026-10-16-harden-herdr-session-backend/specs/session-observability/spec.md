## ADDED Requirements

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
