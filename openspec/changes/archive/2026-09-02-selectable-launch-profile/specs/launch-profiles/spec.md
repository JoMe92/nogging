## ADDED Requirements

### Requirement: A supervised session runs under a selectable authority profile

`scripts/specforge session launch` SHALL accept a `--profile` option and a
`--prompt` option, each taking either a name that resolves under a configured
profile / prompt directory or a filesystem path. When `--profile` is not given,
launch SHALL use the restricted profile; when `--prompt` is not given, launch
SHALL use the no-autonomous-claim prompt. Launch SHALL also accept a
`--full-access` option equivalent to selecting the `trusted` profile and the
`autonomous` prompt. If a selected profile or prompt cannot be resolved, launch
SHALL fail before creating any tmux session.

#### Scenario: Named profile is resolved

- **WHEN** `session launch … --profile trusted` runs and `trusted` exists in the profile directory
- **THEN** the session is started under that profile
- **AND** no tmux session is created if the name resolves to nothing

#### Scenario: Path profile is resolved

- **WHEN** `session launch … --profile ./my-profile.json` runs
- **THEN** the file at that path is used as the profile

#### Scenario: Default is unchanged

- **WHEN** `session launch` runs with neither `--profile` nor `--prompt`
- **THEN** the restricted profile and the no-autonomous-claim prompt are used
- **AND** the session behaves exactly as before this capability existed

#### Scenario: `--full-access` selects the trusted pair

- **WHEN** `session launch … --full-access` runs
- **THEN** the session uses the `trusted` profile and the `autonomous` prompt

### Requirement: The restricted profile is the default authority

The profile directory SHALL contain a `restricted` profile that denies pushing
to a remote, remote Dolt sync, destructive shell commands, privilege escalation,
and outbound network access, and this profile SHALL be the one used when
`--profile` is absent. Adding new profiles SHALL NOT change the default.

#### Scenario: Restricted denies push and network

- **WHEN** a session runs under the restricted profile
- **THEN** it cannot push to a git remote or run a remote Dolt sync
- **AND** it cannot make outbound network requests

### Requirement: A fixed command floor cannot be lifted by any profile

`session launch` SHALL merge a fixed set of denied commands — including
recursive force-delete, `sudo`, `dd`, filesystem-format commands, and host
power commands — into the effective permissions of every session, regardless of
which profile is selected or whether the profile was supplied by name or by
path. No profile SHALL be able to grant these commands.

#### Scenario: The floor survives a permissive supplied profile

- **WHEN** a session is launched with a supplied profile that denies none of the floor commands
- **THEN** the effective settings the session runs under still deny every floor command

#### Scenario: The floor applies to the trusted profile

- **WHEN** a session runs under the `trusted` profile
- **THEN** it still cannot run `sudo` or a recursive force-delete

### Requirement: The effective authority of a session is recorded and listed

`session launch` SHALL write the merged, floored settings for a session to a
per-session file and pass that file — not the source profile — to the launched
process, without modifying the source profile. The session metadata record
SHALL store the selected profile and the path to the effective settings.
`session list` SHALL show the profile each session runs under. `session cleanup`
SHALL remove the per-session effective-settings file when it retires the record.

#### Scenario: The profile is visible after launch

- **WHEN** a session has been launched under the `trusted` profile
- **AND** an operator runs `session list`
- **THEN** the listing shows that the session runs under `trusted`

#### Scenario: Source profiles are not mutated

- **WHEN** a session is launched under any profile
- **THEN** the source profile file is unchanged
- **AND** a separate effective-settings file for that session exists and is referenced by the metadata record

#### Scenario: Cleanup removes the effective settings

- **WHEN** a session record is retired by `session cleanup`
- **THEN** that session's effective-settings file is removed
