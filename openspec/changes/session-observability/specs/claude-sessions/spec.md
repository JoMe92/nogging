## MODIFIED Requirements

### Requirement: Each session has an inspectable log

Each launched session SHALL stream its console output to an append-only log
file whose path is recorded in the session metadata. The log SHALL be readable
without attaching to the tmux session. Log file growth SHALL be bounded by a
configured size limit with rotation. A Claude Code session MAY additionally
have a structured events file (`<name>.events.jsonl`) written by its own
hooks; where present, this file supplements the console log and SHALL NOT
replace it — the console log remains the complete record regardless of
whether the events file exists.

#### Scenario: Session output is captured to a log

- **WHEN** a session produces console output
- **THEN** that output is appended to the session's log file
- **AND** the log file path is present in the session's metadata record

#### Scenario: The log is readable without attaching

- **WHEN** an operator reads or follows a session's log from an SSH shell
- **THEN** they see the session's output
- **AND** they do not attach to or disturb the tmux session

#### Scenario: Log size is bounded

- **WHEN** a session's log file reaches the configured size limit
- **THEN** it is rotated
- **AND** the active log file does not grow without bound

#### Scenario: An events file supplements, never replaces, the console log

- **WHEN** a Claude Code session has written at least one line to its
  `<name>.events.jsonl`
- **THEN** the session's console log is still complete and still readable on
  its own
