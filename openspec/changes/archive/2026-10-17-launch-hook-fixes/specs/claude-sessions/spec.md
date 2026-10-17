## MODIFIED Requirements

### Requirement: Launch refuses a Lead or specialist session for a Bead with an unmet recorded dependency

For `--role lead` or `--role specialist:*`, `session launch` SHALL consult
the target Bead's recorded dependencies and SHALL refuse to create any
tmux session or metadata record when one or more of its **blocking**
dependencies has a status other than `closed`, naming every such blocking
Bead ID in its failure message. A dependency blocks only when its edge type is
`blocks` or no edge type is recorded; `parent-child` links (for example to an
open epic) and every other non-blocking edge type SHALL NOT count.
`--role orchestrator` SHALL be unaffected, and a Bead with no blocking recorded
dependency SHALL be unaffected.

#### Scenario: A blocked Bead is refused

- **WHEN** `session launch --role lead --bead <id>` runs
- **AND** `<id>` has a recorded blocking dependency on a Bead that is not `closed`
- **THEN** the command exits non-zero, names the blocking Bead ID in its
  message
- **AND** no tmux session and no session metadata record are created

#### Scenario: A ready Bead is unaffected

- **WHEN** `session launch --role lead --bead <id>` runs
- **AND** `<id>` has no recorded blocking dependency, or every recorded
  blocking dependency is `closed`
- **THEN** the session launches exactly as before this requirement existed

#### Scenario: An open parent epic does not block its child

- **WHEN** `session launch --role lead --bead <id>` runs
- **AND** the only non-closed recorded dependency of `<id>` is a `parent-child` link to an open epic
- **THEN** the session launches

#### Scenario: A real blocker is named alongside an open epic parent

- **WHEN** `<id>` has an open `parent-child` epic and an open `blocks` dependency
- **THEN** the launch is refused and the message names the blocker but not the epic

#### Scenario: The orchestrator role is unaffected

- **WHEN** `session launch --role orchestrator` runs
- **THEN** no dependency check applies, regardless of any `--bead` value
  (which is ignored for this role in any case)

### Requirement: A Claude-only hook refuses a blocked launch one step earlier

A `PreToolUse` hook on the `Bash` tool SHALL detect a `scripts/nogg session
launch` command carrying `--role lead` or a `--role specialist:` value
together with a `--bead <id>` argument, and SHALL exit with a blocking
status and a stderr message naming the blocking Bead ID(s) when that Bead
has an unmet **blocking** recorded dependency (the same edge-type rule as
`session launch`: type `blocks` or none recorded, status not `closed`),
before the underlying `Bash` tool call runs. A non-matching `Bash` command,
or a matching one for a ready Bead, SHALL proceed unaffected.

#### Scenario: The hook blocks before the tool call runs

- **WHEN** a Claude Code session attempts a `Bash` tool call whose command is
  `scripts/nogg session launch --role lead --bead <id>` for a Bead with an
  unmet blocking recorded dependency
- **THEN** the tool call is blocked with a message naming the blocking Bead
  ID
- **AND** `scripts/nogg` itself is never invoked

#### Scenario: A non-matching command is unaffected

- **WHEN** a Claude Code session attempts any `Bash` tool call that is not a
  matching `session launch` invocation
- **THEN** the hook exits without blocking it

#### Scenario: The hook ignores a parent-child epic

- **WHEN** the matching launch targets a Bead whose only open recorded dependency is a `parent-child` link
- **THEN** the hook exits without blocking it

## ADDED Requirements

### Requirement: Launch fails fast when the agent cannot start

`session launch` SHALL verify before any side effect that the selected agent's
executable resolves on the launcher's `PATH`, and on a miss SHALL refuse with a
message naming the binary (`agent binary '<name>' not found on PATH`) and exit
non-zero, creating no session record, log, usage reservation or backend
session. After a successful start it SHALL confirm the session is still alive
after a short bounded settle window; if the session already ended, the launch
SHALL record it `failed`, show the redacted startup-log tail, and exit
non-zero without printing the launch summary's kickoff hint and without
chaining `--kickoff`.

#### Scenario: A missing binary is refused before side effects

- **WHEN** `session launch` selects an agent whose executable is not on `PATH`
- **THEN** it exits non-zero naming the binary
- **AND** no record, log, reservation or backend session was created

#### Scenario: An agent that dies at once is reported

- **WHEN** the backend session ends inside the settle window after start
- **THEN** the command exits non-zero, shows the startup-log tail, and the record is `failed`
- **AND** no kickoff hint is printed and no `--kickoff` message is sent

#### Scenario: A healthy launch is unchanged

- **WHEN** the agent binary resolves and the session survives the settle window
- **THEN** the launch prints its normal summary and kickoff guidance
