## ADDED Requirements

### Requirement: Launch refuses a Lead or specialist session for a Bead with an unmet recorded dependency

For `--role lead` or `--role specialist:*`, `session launch` SHALL consult
the target Bead's recorded dependencies and SHALL refuse to create any
tmux session or metadata record when one or more of them has a status other
than `closed`, naming every such blocking Bead ID in its failure message.
`--role orchestrator` SHALL be unaffected, and a Bead with no recorded
dependency SHALL be unaffected.

#### Scenario: A blocked Bead is refused

- **WHEN** `session launch --role lead --bead <id>` runs
- **AND** `<id>` has a recorded dependency on a Bead that is not `closed`
- **THEN** the command exits non-zero, names the blocking Bead ID in its
  message
- **AND** no tmux session and no session metadata record are created

#### Scenario: A ready Bead is unaffected

- **WHEN** `session launch --role lead --bead <id>` runs
- **AND** `<id>` has no recorded dependency, or every recorded dependency is
  `closed`
- **THEN** the session launches exactly as before this requirement existed

#### Scenario: The orchestrator role is unaffected

- **WHEN** `session launch --role orchestrator` runs
- **THEN** no dependency check applies, regardless of any `--bead` value
  (which is ignored for this role in any case)

### Requirement: A Claude-only hook refuses a blocked launch one step earlier

A `PreToolUse` hook on the `Bash` tool SHALL detect a `scripts/nogg session
launch` command carrying `--role lead` or a `--role specialist:` value
together with a `--bead <id>` argument, and SHALL exit with a blocking
status and a stderr message naming the blocking Bead ID(s) when that Bead
has an unmet recorded dependency, before the underlying `Bash` tool call
runs. A non-matching `Bash` command, or a matching one for a ready Bead,
SHALL proceed unaffected.

#### Scenario: The hook blocks before the tool call runs

- **WHEN** a Claude Code session attempts a `Bash` tool call whose command is
  `scripts/nogg session launch --role lead --bead <id>` for a Bead with an
  unmet recorded dependency
- **THEN** the tool call is blocked with a message naming the blocking Bead
  ID
- **AND** `scripts/nogg` itself is never invoked

#### Scenario: A non-matching command is unaffected

- **WHEN** a Claude Code session attempts any `Bash` tool call that is not a
  matching `session launch` invocation
- **THEN** the hook exits without blocking it

### Requirement: `doctor` flags a running session whose Bead became blocked after launch

`scripts/nogg doctor` SHALL report a `NOTE` for every currently `running`
Lead or specialist session whose `--bead` has a recorded, unmet dependency,
naming the session and the blocking Bead ID(s), without stopping or
otherwise changing that session.

#### Scenario: A retroactively blocked running session is flagged

- **WHEN** a dependency is recorded against a running Lead session's Bead
  after that session already launched
- **AND** an operator runs `scripts/nogg doctor`
- **THEN** its output includes a `NOTE` naming that session and the
  blocking Bead ID
