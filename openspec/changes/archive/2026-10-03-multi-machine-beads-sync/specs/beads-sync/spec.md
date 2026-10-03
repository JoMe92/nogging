## ADDED Requirements

### Requirement: Multi-machine mode propagates Beads via explicit session-boundary sync

Nogging SHALL provide an opt-in `multi_machine` configuration key, default
`false`. When `true`, a `trusted` or orchestrator-level session SHALL pull
the Beads Dolt remote once at session start, before reading Beads state, and
SHALL push it before ending the session if the session made any Bead write.
A `restricted` session's behavior SHALL be unaffected by this setting — it
writes Beads locally exactly as when the setting is off, and its writes
reach the remote through a later trusted/orchestrator session's push on the
same machine. The default (`false`) SHALL leave every existing behavior
unchanged.

#### Scenario: A trusted session pulls at start and pushes at end

- **WHEN** `multi_machine` is `true`
- **AND** a `trusted` session starts, reads Beads state, makes a Bead write,
  and ends
- **THEN** it pulled the Dolt remote before reading Beads state
- **AND** it pushed the Dolt remote before ending, carrying that write

#### Scenario: A restricted session is unaffected

- **WHEN** `multi_machine` is `true`
- **AND** a `restricted` session makes a Bead write
- **THEN** the write lands in the local Dolt history
- **AND** the session attempts no push and no pull

#### Scenario: The default leaves behavior unchanged

- **WHEN** `multi_machine` is absent or `false`
- **THEN** no session pulls or pushes the Dolt remote as a consequence of
  this requirement
