## MODIFIED Requirements

### Requirement: A supervised session runs the selected agent

`scripts/specforge session launch` SHALL accept an `--agent` option with the
values `claude`, `codex`, and `pi`. When `--agent` is absent, launch SHALL use
the `session_agent` value from `.specforge/config.json`, defaulting to
`claude`. The chosen agent SHALL be recorded in the session metadata and
SHALL be shown by `session list`. A launch with `--agent claude`, or with no
agent selection and the default config, SHALL behave exactly as it did
before this capability existed. A Claude Code launch SHALL additionally wire
`Stop` and `Notification` hooks into the per-session effective-settings file
that invoke `session emit` to append structured state events, without
removing or reordering any existing hook entry already in that file.

#### Scenario: Default launch is unchanged

- **WHEN** `session launch` runs with no `--agent` and no `session_agent` config override
- **THEN** the launched process is Claude Code
- **AND** the session record, log, and lifecycle are exactly as before

#### Scenario: Codex is launched on request

- **WHEN** `session launch --agent codex …` runs
- **THEN** the launched process is Codex, inside the SpecForge tmux server, with the same record and pipe-pane log
- **AND** the session metadata records `codex` as the agent

#### Scenario: Pi is launched on request

- **WHEN** `session launch --agent pi …` runs
- **THEN** the launched process is Pi, inside the SpecForge tmux server, with the same record and pipe-pane log
- **AND** the session metadata records `pi` as the agent

#### Scenario: The agent is visible

- **WHEN** a session has been launched with `--agent codex`
- **AND** an operator runs `session list`
- **THEN** the listing shows that the session runs `codex`

#### Scenario: A Claude launch wires the observability hooks

- **WHEN** `session launch` runs with `--agent claude` (or no `--agent`)
- **THEN** the per-session effective-settings file contains `Stop` and
  `Notification` hook entries invoking `session emit`
- **AND** every hook entry the selected profile already specified is still
  present and in its original order
