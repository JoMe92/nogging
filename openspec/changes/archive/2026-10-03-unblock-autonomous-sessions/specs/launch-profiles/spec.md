## ADDED Requirements

### Requirement: The trusted profile does not block on a first-time Bash approval prompt

The `trusted` profile SHALL set `permissions.defaultMode` to a mode that does
not require an interactive approval the first time a session runs a Bash
command that would otherwise need one (a piped command, a command with shell
expansion, a command that `cd`s before running, and similar categories). A
genuinely unattended `--full-access` session SHALL be able to run such a
command without an operator present to answer a prompt.

#### Scenario: A fresh full-access session does not hang on its first qualifying Bash command

- **WHEN** a session is launched with `--full-access` (the `trusted` profile)
- **AND** it runs a Bash command that would require approval under
  `acceptEdits` mode
- **THEN** the command proceeds without an interactive prompt blocking the
  session

#### Scenario: The trusted profile's deny list is unaffected

- **WHEN** a session runs under the `trusted` profile
- **THEN** it still cannot run any command the profile's `deny` list names,
  regardless of the `defaultMode` value
