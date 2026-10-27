## MODIFIED Requirements

### Requirement: A supervised session runs the selected agent

`scripts/nogg session launch` SHALL accept an `--agent` option with the
values `claude`, `codex`, `pi`, and `antigravity` (with `agy` accepted as an alias normalized to `antigravity`). When `--agent` is absent and the
project's agent routing file has a list for the launch role, the agent SHALL
come from that list as the agent-routing capability specifies. When `--agent`
is absent and the role has no routing list, launch SHALL use the
`session_agent` value from `.nogging/config.json`, defaulting to `claude`. The
chosen agent SHALL be recorded in the session metadata and SHALL be shown by
`session list`. A launch with `--agent claude`, or with no agent selection, no
routing list for the role and the default config, SHALL behave exactly as it
did before this capability existed. A Claude Code launch SHALL additionally
wire `Stop` and `Notification` hooks into the per-session effective-settings
file that invoke `session emit` to append structured state events, without
removing or reordering any existing hook entry already in that file.

#### Scenario: Default launch is unchanged

- **WHEN** `session launch` runs with no `--agent`, no `session_agent` config override and no routing list for the role
- **THEN** the launched process is Claude Code
- **AND** the session record, log, and lifecycle are exactly as before

#### Scenario: A routing list replaces the session_agent default

- **WHEN** `session launch --role lead` runs with no `--agent`, `session_agent` is `claude`, and the routing file's `lead` list starts with an admitted Codex entry
- **THEN** the launched process is Codex and the record carries the routing decision

#### Scenario: Codex is launched on request

- **WHEN** `session launch --agent codex …` runs
- **THEN** the launched process is Codex, inside the Nogging tmux server, with the same record and pipe-pane log
- **AND** the session metadata records `codex` as the agent

#### Scenario: Pi is launched on request

- **WHEN** `session launch --agent pi …` runs
- **THEN** the launched process is Pi, inside the Nogging tmux server, with the same record and pipe-pane log
- **AND** the session metadata records `pi` as the agent

#### Scenario: The agent is visible

- **WHEN** a session has been launched with `--agent codex`
- **AND** an operator runs `session list`
- **THEN** the listing shows that the session runs `codex`

#### Scenario: A Claude launch wires the observability hooks

- **WHEN** `session launch` runs with `--agent claude` (or with no `--agent` and Claude is the selected agent)
- **THEN** the per-session effective-settings file contains `Stop` and
  `Notification` hook entries invoking `session emit`
- **AND** every hook entry the selected profile already specified is still
  present and in its original order

#### Scenario: Antigravity is selected explicitly

- **WHEN** session launch runs with --agent agy or --agent antigravity
- **THEN** a supervised Antigravity process starts and records antigravity as its agent
