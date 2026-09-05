## MODIFIED Requirements

### Requirement: A supervised session runs the selected agent

`scripts/specforge session launch` SHALL accept an `--agent` option with the
values `claude`, `codex`, and `pi`. When `--agent` is absent, launch SHALL use
the `session_agent` value from `.specforge/config.json`, defaulting to
`claude`. The chosen agent SHALL be recorded in the session metadata and
SHALL be shown by `session list`. A launch with `--agent claude`, or with no
agent selection and the default config, SHALL behave exactly as it did
before this capability existed.

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

### Requirement: Authority levels resolve per agent

The `restricted` and `trusted` authority levels SHALL resolve to an
agent-appropriate launch specification: for `claude`, the existing Claude
settings file; for `codex`, a Codex launch specification giving a sandbox
mode, an approval policy, and a network setting; for `pi`, a launch that
keeps the SpecForge command-floor extension (`.pi/extensions/`) active and,
for `trusted`, uses the autonomous prompt. `restricted` SHALL remain the
default level for all three agents. For `claude` and `codex`, `restricted`
SHALL deny outbound network access and require approval for non-trivial
actions. For `pi`, `restricted` enforces the command floor and the
`openspec/` write boundary only — Pi has no native sandbox, so no network or
filesystem isolation exists under either level; this is a strictly weaker
guarantee than the `claude` and `codex` `restricted` level, and is reported
as such rather than presented as equivalent. A `--profile` value that is a
Claude or Codex settings file used with a different `--agent` SHALL be
rejected before any session is created.

#### Scenario: Restricted maps to a constrained Codex launch

- **WHEN** `session launch --agent codex` runs with no `--profile`
- **THEN** Codex is started with a workspace-write sandbox, an approval policy that is not `never`, and network access disabled

#### Scenario: Trusted maps to an autonomous Codex launch

- **WHEN** `session launch --agent codex --full-access` runs
- **THEN** Codex is started with approval policy `never` and the autonomous prompt
- **AND** network access is still disabled

#### Scenario: Restricted maps to a floor-only Pi launch

- **WHEN** `session launch --agent pi` runs with no `--profile`
- **THEN** Pi is started with the `.pi/extensions/` guard active and the default (non-autonomous) prompt
- **AND** no network or filesystem sandbox is applied — the floor extension and the write boundary are the only enforcement

#### Scenario: Trusted maps to an autonomous Pi launch

- **WHEN** `session launch --agent pi --full-access` runs
- **THEN** Pi is started with the autonomous prompt
- **AND** the guard extension is still active — `trusted` never disables the floor

#### Scenario: A Claude profile with the Codex agent is refused

- **WHEN** `session launch --agent codex --profile ./some-claude-settings.json` runs
- **THEN** the launch fails with a message that the file is a Claude profile
- **AND** no session record, log, or tmux session is created

### Requirement: Codex availability is reported but not required

`scripts/specforge doctor` SHALL report whether `codex` and `pi` are each
available as an informational note. A missing `codex` or `pi` SHALL NOT make
`doctor` fail or change its exit code.

#### Scenario: Codex absent does not fail doctor

- **WHEN** `doctor` runs on a host without `codex` installed
- **THEN** it notes that `codex` is not available
- **AND** it does not report a failure for `codex` and its exit code is unchanged

#### Scenario: Pi absent does not fail doctor

- **WHEN** `doctor` runs on a host without `pi` installed
- **THEN** it notes that `pi` is not available
- **AND** it does not report a failure for `pi` and its exit code is unchanged
