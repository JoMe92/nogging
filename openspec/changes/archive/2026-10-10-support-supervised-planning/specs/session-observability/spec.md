## MODIFIED Requirements

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
