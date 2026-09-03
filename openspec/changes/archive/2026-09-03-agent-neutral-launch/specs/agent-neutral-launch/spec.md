## ADDED Requirements

### Requirement: A supervised session runs the selected agent

`scripts/specforge session launch` SHALL accept an `--agent` option with the
values `claude` and `codex`. When `--agent` is absent, launch SHALL use the
`session_agent` value from `.specforge/config.json`, defaulting to `claude`. The
chosen agent SHALL be recorded in the session metadata and SHALL be shown by
`session list`. A launch with `--agent claude`, or with no agent selection and
the default config, SHALL behave exactly as it did before this capability
existed.

#### Scenario: Default launch is unchanged

- **WHEN** `session launch` runs with no `--agent` and no `session_agent` config override
- **THEN** the launched process is Claude Code
- **AND** the session record, log, and lifecycle are exactly as before

#### Scenario: Codex is launched on request

- **WHEN** `session launch --agent codex …` runs
- **THEN** the launched process is Codex, inside the SpecForge tmux server, with the same record and pipe-pane log
- **AND** the session metadata records `codex` as the agent

#### Scenario: The agent is visible

- **WHEN** a session has been launched with `--agent codex`
- **AND** an operator runs `session list`
- **THEN** the listing shows that the session runs `codex`

### Requirement: Authority levels resolve per agent

The `restricted` and `trusted` authority levels SHALL resolve to an
agent-appropriate launch specification: for `claude`, the existing Claude
settings file; for `codex`, a Codex launch specification giving a sandbox mode,
an approval policy, and a network setting. `restricted` SHALL remain the default
level for both agents, and SHALL deny outbound network access and require
approval for non-trivial actions. A `--profile` value that is a Claude settings
file used with `--agent codex` SHALL be rejected before any session is created.

#### Scenario: Restricted maps to a constrained Codex launch

- **WHEN** `session launch --agent codex` runs with no `--profile`
- **THEN** Codex is started with a workspace-write sandbox, an approval policy that is not `never`, and network access disabled

#### Scenario: Trusted maps to an autonomous Codex launch

- **WHEN** `session launch --agent codex --full-access` runs
- **THEN** Codex is started with approval policy `never` and the autonomous prompt
- **AND** network access is still disabled

#### Scenario: A Claude profile with the Codex agent is refused

- **WHEN** `session launch --agent codex --profile ./some-claude-settings.json` runs
- **THEN** the launch fails with a message that the file is a Claude profile
- **AND** no session record, log, or tmux session is created

### Requirement: The command floor stays in force for a Codex session

`session launch --agent codex` SHALL NOT disable the SpecForge command floor: it
SHALL NOT pass Codex any flag that ignores project execution-policy rules or
that bypasses the sandbox and approvals. When the repository's execution-policy
floor file is absent at launch time, launch SHALL warn, naming the missing file,
and continue.

#### Scenario: The floor is not bypassed

- **WHEN** a Codex session is launched under any level
- **THEN** the Codex invocation contains no flag that ignores project rules and no flag that bypasses sandboxing and approvals

#### Scenario: A missing floor file is surfaced

- **WHEN** `session launch --agent codex` runs and the repository has no execution-policy floor file
- **THEN** the launch prints a warning that names the missing file
- **AND** the session still starts

### Requirement: Codex availability is reported but not required

`scripts/specforge doctor` SHALL report whether `codex` is available as an
informational note. A missing `codex` SHALL NOT make `doctor` fail or change its
exit code.

#### Scenario: Codex absent does not fail doctor

- **WHEN** `doctor` runs on a host without `codex` installed
- **THEN** it notes that `codex` is not available
- **AND** it does not report a failure for `codex` and its exit code is unchanged
