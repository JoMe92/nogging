## ADDED Requirements

### Requirement: Closing a Bead can tick its task line immediately

Nogging SHALL provide a command that ticks a single closed, mapped Bead's
`tasks.md` checkbox immediately, independent of the sync timer's schedule.
The command SHALL refuse when the named Bead is not closed. It SHALL use the
same tick logic the timer-driven sync uses, so the two paths never disagree
about what "ticked" means, and ticking the same line twice (once
synchronously, once later by the timer) SHALL be a no-op the second time.

#### Scenario: A closed Bead's task line ticks without waiting for the timer

- **WHEN** a Bead mapped to a live change's task is closed
- **AND** the immediate-tick command is run for that Bead
- **THEN** the matching `tasks.md` line shows `[x]` before the next scheduled
  sync tick runs

#### Scenario: An open Bead is refused

- **WHEN** the immediate-tick command is run for a Bead that is not closed
- **THEN** it refuses and ticks nothing

#### Scenario: A later sync tick does not double-write an already-ticked line

- **WHEN** a Bead's task line was already ticked by the immediate-tick command
- **AND** the timer-driven sync later processes the same closed Bead
- **THEN** the sync makes no further change to that line
