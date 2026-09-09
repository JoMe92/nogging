## MODIFIED Requirements

### Requirement: A fixed command floor cannot be lifted by any profile

`session launch` SHALL merge a fixed set of denied commands — including
recursive force-delete, `sudo`, `dd`, filesystem-format commands, and host
power commands — into the effective permissions of every session, regardless of
which profile is selected or whether the profile was supplied by name or by
path. No profile SHALL be able to grant these commands.

The **single exception** is `--role orchestrator` launched under a profile
whose `specforge_floor` key is `false` (the shipped `orchestrator` profile).
For that role and that key only, `session launch` SHALL skip the floor merge,
and SHALL likewise skip the per-session `openspec/**` read-only rules when
`specforge_openspec_readonly` is `false`. Both keys SHALL be ignored — the
floor and the boundary applied as normal — for every other role, so a `lead`
or `specialist` session pointed at the `orchestrator` profile still runs
floored and `openspec/`-fenced. A session that actually ran with the floor
lifted SHALL be recorded and shown by `session list` as `FULL-ACCESS`.

#### Scenario: The floor survives a permissive supplied profile

- **WHEN** a session is launched with a supplied profile that denies none of the floor commands
- **THEN** the effective settings the session runs under still deny every floor command

#### Scenario: The floor applies to the trusted profile

- **WHEN** a session runs under the `trusted` profile
- **THEN** it still cannot run `sudo` or a recursive force-delete

#### Scenario: A non-orchestrator role cannot lift the floor via the orchestrator profile

- **WHEN** a `lead` session is launched with `--profile orchestrator`
- **THEN** its effective settings still deny every floor command
- **AND** they still deny `Edit`/`Write` under `openspec/**` outside a planning session

#### Scenario: The orchestrator role under the orchestrator profile runs floor-less

- **WHEN** a session is launched with `--role orchestrator` under the `orchestrator` profile (`specforge_floor: false`)
- **THEN** its effective settings deny none of the floor commands
- **AND** `session list` shows the session as `FULL-ACCESS`

## ADDED Requirements

### Requirement: The orchestrator profile grants unrestricted authority to the orchestrator role

The profile directory SHALL contain an `orchestrator` profile that runs in
`bypassPermissions` mode with an empty deny list and carries
`specforge_floor: false` and `specforge_openspec_readonly: false`. Combined
with `--role orchestrator` it grants the session full command access, outbound
network, and `openspec/` write access. Selecting it does not change the
default authority for any other launch. The profile SHALL be Claude-only in
this version.

#### Scenario: The orchestrator profile is the unrestricted level

- **WHEN** `session launch --role orchestrator --profile orchestrator` runs
- **THEN** the session can run any command, reach the network, and write under `openspec/`

#### Scenario: The default is unchanged

- **WHEN** `session launch` runs with neither `--profile` nor `--role orchestrator`
- **THEN** the restricted profile and the full command floor apply exactly as before this capability existed
