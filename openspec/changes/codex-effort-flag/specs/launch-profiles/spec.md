## MODIFIED Requirements

### Requirement: Claude effort has validated session-scoped precedence

Claude JSON launch profiles SHALL accept optional `effort`, and `scripts/nogg session launch` SHALL accept `--effort <level>` for the resolved Claude agent. For Claude the allowed values SHALL be exact strings `low`, `medium`, `high`, `xhigh`, and `max`. Launch SHALL validate both provided inputs, then select launch override over profile effort over native runtime behavior. A present invalid profile value SHALL refuse even when overridden. Omission SHALL emit no effort flag and preserve native behavior. `model_reasoning_effort` SHALL remain Codex-only; `effort` SHALL be rejected in non-Claude profiles, and `--effort` SHALL refuse for Pi and Antigravity launches (Codex is covered by the Codex effort requirement). Refusal SHALL occur before session/worktree creation, settings/record writes or tmux creation. Model selection SHALL remain independent.

#### Scenario: Launch override wins

- **WHEN** a Claude profile specifies `effort: high` and launch specifies `--effort low`
- **THEN** the requested effort is low with source launch
- **AND** the source profile remains unchanged

#### Scenario: Profile or native behavior

- **WHEN** Claude launches without an effort override
- **THEN** a valid profile effort is selected with source profile
- **AND** if the profile omits effort, no effort flag is emitted and the source is runtime-default

#### Scenario: Invalid values fail before side effects

- **WHEN** an effort input is null, non-string, empty, whitespace-bearing, case-mismatched or outside the allowed values, including an invalid profile with a valid override
- **THEN** launch refuses with a diagnostic identifying the offending input
- **AND** no session worktree, effective settings, session record or tmux session is created

#### Scenario: Cross-agent inputs refuse

- **WHEN** --effort targets Pi or Antigravity, a non-Claude profile contains effort, or a Claude profile contains model_reasoning_effort
- **THEN** launch refuses before session creation rather than dropping or translating the setting
- **AND** valid existing Codex model_reasoning_effort behavior remains unchanged

## ADDED Requirements

### Requirement: Codex effort can be set at launch

`scripts/nogg session launch --agent codex` SHALL accept `--effort <level>`. The level SHALL be validated against the supported Codex reasoning-effort set (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`) before any side effect. A valid level SHALL reach Codex through the existing `--reasoning-effort` transport as separate argv elements, with no new public Codex flag. Codex effort precedence SHALL be launch `--effort` over `--tier` table effort over profile `model_reasoning_effort` over the runtime default. An explicit effort SHALL be recorded as `reasoning_effort` with source `launch`, shown by `session list` as `effort=<level> (launch)`. An invalid `--effort` SHALL refuse even when a tier or profile would supply a valid value. Refusal SHALL occur before session/worktree creation, settings/record writes or tmux creation. Without `--effort`, Codex behaviour SHALL be unchanged. Whether a given model supports a level SHALL remain the runtime's decision, and a runtime rejection SHALL follow the existing failed-start lifecycle without a retry at another effort.

#### Scenario: Effort overrides the tier effort

- **WHEN** a Codex session launches with `--tier complex --effort low`
- **THEN** Codex receives `--reasoning-effort low` and the tier's model
- **AND** the record stores reasoning_effort low with source launch

#### Scenario: Effort overrides the profile effort

- **WHEN** a Codex profile sets `model_reasoning_effort = "xhigh"` and launch passes `--effort low`
- **THEN** Codex receives `--reasoning-effort low` and the source profile is unchanged

#### Scenario: Effort without a tier

- **WHEN** a Codex session launches with `--effort medium` and no tier or profile effort
- **THEN** Codex receives `--reasoning-effort medium` with source launch

#### Scenario: Unsupported level is refused

- **WHEN** a Codex launch passes `--effort turbo`, `--effort LOW` or an empty value
- **THEN** launch refuses naming the input and the allowed values
- **AND** no worktree, settings, record or tmux session is created

#### Scenario: Pi and Antigravity still refuse

- **WHEN** `--effort` targets Pi, Antigravity or the `agy` alias
- **THEN** launch refuses naming Claude and Codex as the only supported agents
