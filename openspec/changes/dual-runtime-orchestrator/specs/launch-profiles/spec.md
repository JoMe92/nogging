## MODIFIED Requirements

### Requirement: A fixed command floor cannot be lifted by any profile

`session launch` SHALL apply the existing fixed denied-command floor to every ordinary role under every named or path-supplied profile. The single exception SHALL remain the orchestrator role explicitly using the orchestrator authority profile with `nogging_floor: false`; only that combination SHALL permit a role-scoped floor exception. Its `nogging_openspec_readonly: false` SHALL likewise disable only that orchestrator's execution fence. Both switches SHALL be ignored or rejected for every other role. This SHALL hold for Claude and Codex, including a Codex launch through Happier. Implementation SHALL NOT modify shared repository rules, global execpolicy, user trust or another session's permissions to express the exception. Unsupported scoped authority SHALL refuse before launch. Actual lifted authority SHALL be recorded and displayed as FULL-ACCESS.

#### Scenario: The floor survives a permissive supplied profile

- **WHEN** an ordinary session launches with a profile that denies none of the floor commands
- **THEN** it retains every floor restriction or the launch is refused before any session is created

#### Scenario: The floor applies to the trusted profile

- **WHEN** an ordinary session runs under the trusted profile
- **THEN** sudo and recursive force-delete remain denied

#### Scenario: A non-orchestrator role cannot lift the floor via the orchestrator profile

- **WHEN** a Claude or Codex lead, planning or specialist session selects the orchestrator profile
- **THEN** it receives only its normal role authority and floor or is refused before side effects
- **AND** an execution role retains its OpenSpec fence

#### Scenario: The orchestrator role under the orchestrator profile runs floor-less

- **WHEN** a supported Claude or Codex orchestrator launches under the explicit orchestrator profile
- **THEN** only that session receives the verified floor/fence exception and is shown as FULL-ACCESS
- **AND** shared policies and other sessions remain unchanged

### Requirement: The orchestrator profile grants unrestricted authority to the orchestrator role

The profile directory SHALL ship Claude `orchestrator.json` and Codex `orchestrator.codex.toml` variants for the existing orchestrator authority. Claude SHALL retain bypassPermissions, its disclaimer prerequisite and the role-only floor/fence switches. Codex SHALL use a verified per-invocation unrestricted host policy, no interactive approvals and network access, including the same role-only floor/fence switches. The shared persona SHALL retain orchestrate-only default scope, explicit one-task takeover, a canonical planning lock for planning writes, claimed-Bead execution and human-only sign-off. Selecting these profiles SHALL NOT change the default authority of any other launch. Pi and other runtime variants remain unsupported. Profile contents SHALL be preserved as source files; any effective runtime policy SHALL be session-scoped and recorded.

#### Scenario: The orchestrator profile is the unrestricted level

- **WHEN** an explicitly selected Claude or Codex orchestrator launches with its supported orchestrator profile
- **THEN** its effective runtime can use host commands and network without interactive approvals and without an execution OpenSpec fence
- **AND** its prompt still requires an explicit takeover and the planning lock before planning work

#### Scenario: The default is unchanged

- **WHEN** an ordinary session launches without explicit authority
- **THEN** its existing restricted default and full command floor remain in effect

#### Scenario: Codex policy cannot be isolated

- **WHEN** the installed Codex runtime cannot apply the requested orchestrator authority without changing shared/global rules
- **THEN** launch refuses with a concrete compatibility explanation before starting an agent
- **AND** the shared/global policy files remain unchanged

#### Scenario: Source profiles are preserved

- **WHEN** either orchestrator runtime starts
- **THEN** its effective authority and policy provenance are recorded without modifying the source profile or user-global configuration
