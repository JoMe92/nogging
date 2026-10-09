## MODIFIED Requirements

### Requirement: Discovery review surfaces closed discoveries

Discovery review SHALL enumerate every Bead carrying the `discovery` label
regardless of the Bead's status, so that a discovery closed before a planning
session reviews it is not omitted. A discovery that a planning session has
explicitly acknowledged SHALL stop being surfaced; a discovery that has not been
acknowledged SHALL keep being surfaced whether it is open or closed. Acknowledgements SHALL be stored in repository-shared durable state and remain visible across linked worktrees and after their cleanup. Writes SHALL be atomic and concurrent additions SHALL not lose earlier acknowledgements. Existing per-checkout ledgers SHALL be merged without erasing any acknowledged ID. Blocking
discoveries SHALL continue to be presented before non-blocking ones.

#### Scenario: An open discovery is listed

- **WHEN** an open Bead carries the `discovery` label and has not been acknowledged
- **THEN** discovery review lists it

#### Scenario: A closed, unacknowledged discovery is listed

- **WHEN** a Bead carries the `discovery` label, is closed, and has not been acknowledged
- **THEN** discovery review lists it and marks it as closed and awaiting review

#### Scenario: An acknowledged discovery is not listed

- **WHEN** a planning session has acknowledged a discovery-labelled Bead
- **THEN** discovery review no longer lists that Bead, regardless of its status

#### Scenario: Blocking discoveries are ordered first

- **WHEN** discovery review lists more than one pending discovery
- **THEN** discoveries whose Bead status is `blocked` appear before the others
## ADDED Requirements

### Requirement: Discovery acknowledgements survive planning worktree retirement

Discovery acknowledgements SHALL remain effective when the planning worktree that recorded them is removed.

#### Scenario: Retire the acknowledging worktree

- **WHEN** a discovery is acknowledged in a planning worktree and that worktree is safely retired
- **THEN** the main checkout and another worktree still omit that discovery from the pending review
