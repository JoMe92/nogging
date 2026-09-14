## ADDED Requirements

### Requirement: The complete Claude Code payload is installed and refreshed

The installer SHALL deliver every repository-owned Claude Code specialist
definition under `.claude/agents/` and every repository-owned workflow command
under `.claude/commands/`. These files SHALL be present in the packaged
distribution and SHALL be copied verbatim on both `init` and `update`.

#### Scenario: Fresh install delivers Claude agents and commands

- **WHEN** `init` runs in a fresh target repository
- **THEN** every source file under `.claude/agents/` is present at the same path in the target repository
- **AND** every source file under `.claude/commands/` is present at the same path in the target repository

#### Scenario: Update refreshes the Claude payload

- **WHEN** `update` runs after a released Claude agent or command definition changed
- **THEN** the corresponding target file is replaced with the released version
- **AND** unrelated target-owned `.claude/settings.json` content remains preserved

#### Scenario: Packed install contains the Claude payload

- **WHEN** the package used by `npx github:` is built
- **THEN** it contains every file under `.claude/agents/` and `.claude/commands/`

#### Scenario: Repeated installation is idempotent

- **WHEN** `init` or `update` is repeated without a source payload change
- **THEN** the tracked Claude agent and command files do not change
