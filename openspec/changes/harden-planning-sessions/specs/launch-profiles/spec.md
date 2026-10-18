## MODIFIED Requirements

### Requirement: A supervised session runs under a selectable authority profile

`scripts/specforge session launch` SHALL accept a `--profile` option and a
`--prompt` option, each taking either a name that resolves under a configured
profile / prompt directory or a filesystem path. When `--profile` is not given,
launch SHALL use the restricted profile, except where *The restricted profile
is the default authority* requires an explicit profile; when `--prompt` is not
given, launch SHALL use the no-autonomous-claim prompt, or the planning prompt
for `--role planning`. Launch SHALL also accept a `--full-access` option
equivalent to selecting the `trusted` profile and the `autonomous` prompt. If a
selected profile or prompt cannot be resolved, launch SHALL fail before
creating any tmux session.

#### Scenario: Named profile is resolved

- **WHEN** `session launch … --profile trusted` runs and `trusted` exists in the profile directory
- **THEN** the session is started under that profile
- **AND** no tmux session is created if the name resolves to nothing

#### Scenario: Path profile is resolved

- **WHEN** `session launch … --profile ./my-profile.json` runs
- **THEN** the file at that path is used as the profile

#### Scenario: Default is unchanged

- **WHEN** a lead or specialist `session launch` runs with neither `--profile` nor `--prompt`
- **THEN** the restricted profile and the no-autonomous-claim prompt are used
- **AND** the session behaves exactly as before this capability existed

#### Scenario: `--full-access` selects the trusted pair

- **WHEN** `session launch … --full-access` runs
- **THEN** the session uses the `trusted` profile and the `autonomous` prompt

### Requirement: The restricted profile is the default authority

The profile directory SHALL contain a `restricted` profile that denies pushing
to a remote, remote Dolt sync, destructive shell commands, privilege escalation,
and outbound network access, and this profile SHALL be the one used when
`--profile` is absent. Adding new profiles SHALL NOT change the default. The
one exception is a `--role planning` launch for the `codex` or `antigravity`
agent: with neither `--profile` nor `--full-access` it SHALL be refused before
any side effect, naming `--profile trusted` and `--profile restricted`. It
SHALL NOT fall back to `trusted`.

#### Scenario: Restricted denies push and network

- **WHEN** a session runs under the restricted profile
- **THEN** it cannot push to a git remote or run a remote Dolt sync
- **AND** it cannot make outbound network requests

#### Scenario: Implicit Codex or Antigravity planning launch

- **WHEN** `session launch --role planning --agent codex` or `--agent antigravity` runs with neither `--profile` nor `--full-access`
- **THEN** launch exits non-zero naming both explicit profiles
- **AND** no planning worktree, session record, log or backend session exists afterwards

#### Scenario: Explicit restricted planning

- **WHEN** the same launch passes `--profile restricted`
- **THEN** it proceeds under the restricted profile and prints a note that the session stops at approval prompts

#### Scenario: Claude planning default

- **WHEN** a Claude planning launch gives neither `--profile` nor `--full-access`
- **THEN** it runs under the restricted profile and prints the manual-mode warning

## ADDED Requirements

### Requirement: Launch output names the effective authority

Every successful `session launch` SHALL print the effective profile label and
the prompt name. A restricted Codex launch of any role SHALL also print a note
that a Dolt-server-backed `bd` is unreachable from its network-off sandbox.

#### Scenario: Profile line

- **WHEN** a session launch succeeds
- **THEN** its output contains `profile=<label>` and `prompt=<name>`

#### Scenario: Restricted Codex note

- **WHEN** a Codex session launches under the restricted profile
- **THEN** the output notes that `bd` cannot reach a Dolt server from its sandbox
