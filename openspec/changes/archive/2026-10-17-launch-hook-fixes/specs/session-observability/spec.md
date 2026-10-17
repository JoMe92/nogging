## ADDED Requirements

### Requirement: Claude's Layer-2 hooks run from any working directory

The effective settings written for a launched Claude session SHALL register the
`Stop` (`turn_end`) and `Notification` (`needs_input`) hooks with an absolute,
shell-quoted path to the launching checkout's `scripts/nogg`, resolved when the
settings are written. No generated hook command SHALL depend on the session's
current working directory, so a `cd` into a subdirectory does not lose events.

#### Scenario: Generated hook commands are absolute

- **WHEN** `session launch --agent claude` writes the effective settings
- **THEN** the `Stop` and `Notification` hook commands begin with an absolute quoted `scripts/nogg` path
- **AND** no generated hook command begins with a relative `scripts/` path

#### Scenario: A hook fires after the agent changes directory

- **WHEN** the `Stop` hook command runs with a subdirectory of the checkout as its working directory
- **THEN** it resolves `scripts/nogg` and records the `turn_end` event for the session

#### Scenario: A path with spaces is quoted

- **WHEN** the launching checkout path contains a space
- **THEN** the generated hook commands remain valid shell and resolve correctly
