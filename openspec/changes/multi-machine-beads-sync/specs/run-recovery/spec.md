## ADDED Requirements

### Requirement: doctor reports unpushed local Dolt state under multi-machine mode

When `multi_machine` is enabled and the local Dolt history has commits not
present on the configured remote, `doctor` SHALL report a NOTE naming how
many. This NOTE SHALL NOT fail `doctor` or change its exit code, and SHALL
NOT appear when `multi_machine` is disabled.

#### Scenario: Unpushed Dolt state is surfaced

- **WHEN** `multi_machine` is enabled
- **AND** local Dolt has commits the configured remote does not have
- **AND** `doctor` runs
- **THEN** it prints a NOTE naming the count
- **AND** `doctor`'s exit code is unchanged

#### Scenario: Nothing to report when fully pushed

- **WHEN** `multi_machine` is enabled
- **AND** local Dolt has no commits the remote lacks
- **AND** `doctor` runs
- **THEN** it prints no unpushed-state NOTE

#### Scenario: The check is silent when the mode is off

- **WHEN** `multi_machine` is disabled
- **AND** `doctor` runs
- **THEN** it prints no unpushed-state NOTE regardless of local Dolt state
