## MODIFIED Requirements

### Requirement: A fixed command floor cannot be lifted by any profile

`session launch` SHALL apply the existing fixed denied-command floor to ordinary roles under every named or path-supplied profile. The existing floor exception SHALL remain limited to Claude's explicit orchestrator role/profile with `nogging_floor: false`. Codex SHALL retain all loaded execpolicy denials, including for its orchestrator and Happier variants; no launch SHALL disable, mask, rename or bypass shared/global rules. A Codex denial SHALL be reported without an alternate-command workaround. The execution OpenSpec fence exception SHALL apply only to an explicit orchestrator role/profile; ordinary execution roles SHALL retain their fence. Other roles selecting an orchestrator profile SHALL receive only their normal authority or refuse before side effects. Actual floor-lifted Claude authority SHALL be recorded as FULL-ACCESS; Codex orchestrator host access SHALL be labelled HOST-ACCESS with command floor retained and `floor_lifted: false`.

#### Scenario: The floor survives a permissive supplied profile

- **WHEN** an ordinary session launches under a profile that denies none of the floor commands
- **THEN** it retains the full command floor or launch refuses before creating a session

#### Scenario: The floor applies to the trusted profile

- **WHEN** an ordinary session runs under the trusted profile
- **THEN** sudo and recursive force-delete remain denied

#### Scenario: A non-orchestrator role cannot lift the floor via the orchestrator profile

- **WHEN** a lead, planning or specialist role selects an orchestrator profile
- **THEN** it receives only its normal role authority or is refused before side effects
- **AND** an execution role retains its OpenSpec fence

#### Scenario: The orchestrator role under the orchestrator profile runs floor-less

- **WHEN** the explicit Claude orchestrator launches with its existing floor-lifted profile
- **THEN** only that session receives the exception and its listing shows FULL-ACCESS

#### Scenario: Codex retains execpolicy under host access

- **WHEN** native or Happier-controlled Codex orchestrator runs under its host-access profile
- **THEN** an allowed harmless command can run and a harmless forbidden test sentinel is still denied
- **AND** status records HOST-ACCESS, retained command floor and `floor_lifted: false`

## REMOVED Requirements

### Requirement: The orchestrator profile grants unrestricted authority to the orchestrator role

**Reason**: The verified Codex interfaces retain execpolicy under host access, so authority must be stated separately for each runtime.
**Migration**: Existing Claude orchestrator profiles and FULL-ACCESS labels retain their behavior. Codex uses the new host-access profile with its command floor retained; no rules or user-global policy are migrated or weakened.

## ADDED Requirements

### Requirement: Orchestrator profiles expose verified runtime-specific authority

The profile directory SHALL ship Claude `orchestrator.json` and Codex `orchestrator.codex.toml`. Claude SHALL preserve its current bypassPermissions, disclaimer prerequisites and role-only floor/fence exception. Codex SHALL use verified host execution, no interactive approvals and enabled network while retaining loaded execpolicy. Only the explicit orchestrator role/profile SHALL receive that host policy and exemption from the execution OpenSpec fence. Runtime-specific effective policy, floor status and provenance SHALL be recorded without changing source profiles or user-global configuration. Codex SHALL NOT claim FULL-ACCESS. Both personas SHALL retain orchestrate-only default scope, one-task explicit takeover, canonical planning lock for planning, claimed-Bead execution and human-only sign-off. Codex takeovers SHALL remain subject to execpolicy. Pi and other runtime variants remain unsupported.

#### Scenario: Codex host access is accurately represented

- **WHEN** the Codex orchestrator launches under its explicit profile
- **THEN** its effective sandbox/approval/network and retained rules are verified and reported as HOST-ACCESS
- **AND** global/repository rules and other sessions remain unchanged

#### Scenario: Ordinary defaults remain unchanged

- **WHEN** an ordinary session launches without explicit authority
- **THEN** its existing restricted defaults and full floor remain effective

#### Scenario: Denied takeover action is reported

- **WHEN** a Codex takeover requests an action denied by loaded execpolicy
- **THEN** the denial is reported for operator action without rewriting policy or retrying through another command path

#### Scenario: Planning writes still require takeover and lock

- **WHEN** either orchestrator identifies planning work without an explicit takeover and its canonical planning lock
- **THEN** it directs a planning session instead of making that planning edit itself
