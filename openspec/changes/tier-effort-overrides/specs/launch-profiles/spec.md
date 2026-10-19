## MODIFIED Requirements

### Requirement: Requested reasoning effort and provenance are durable and visible

New Claude and Codex session records SHALL contain `reasoning_effort` and `reasoning_effort_source`. Source SHALL be `launch`, `profile`, `project` or `runtime-default` (`project` only for an effort supplied by a `tier_overrides` entry, with no explicit `--effort`); absent effort SHALL be null with source runtime-default. Codex profile effort SHALL use source profile. Session list SHALL show the requested level and source, or effort=runtime-default when unspecified in new Claude/Codex records. Existing model fields SHALL remain intact. Old records without effort-source SHALL remain readable: present effort SHALL show unknown provenance, and absent effort SHALL retain the prior display. Other agents' display SHALL remain unchanged. These fields SHALL describe the launch request, not imply observation of later interactive changes or runtime-resolved defaults.

#### Scenario: Profile and override provenance

- **WHEN** new Claude sessions select effort from the profile and launch override respectively
- **THEN** records store the selected values with sources profile and launch respectively
- **AND** session list displays those values and sources

#### Scenario: Codex and unspecified effort

- **WHEN** a new Codex session has profile model_reasoning_effort high or a new Claude/Codex session has no effort input
- **THEN** the former stores high with source profile and the latter stores null with source runtime-default
- **AND** listings show the same requested-setting distinction without inventing a runtime value

#### Scenario: Historical records remain readable

- **WHEN** session list reads records predating reasoning_effort_source
- **THEN** a stored effort displays unknown provenance and an absent effort retains the prior display
- **AND** the list succeeds without rewriting those records

#### Scenario: Project override provenance

- **WHEN** a new Claude or Codex session launches with `--tier complex` under a project effort override and no `--effort`
- **THEN** the record stores the override's level with source project
- **AND** session list shows `effort=<level> (project)`

### Requirement: Codex effort can be set at launch

`scripts/nogg session launch --agent codex` SHALL accept `--effort <level>`. The level SHALL be validated against the supported Codex reasoning-effort set (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`) before any side effect. A valid level SHALL reach Codex through the existing `--reasoning-effort` transport as separate argv elements, with no new public Codex flag. Codex effort precedence SHALL be launch `--effort` over the `--tier` effort (a project `tier_overrides` entry, else the table) over profile `model_reasoning_effort` over the runtime default. An explicit effort SHALL be recorded as `reasoning_effort` with source `launch`, shown by `session list` as `effort=<level> (launch)`. An invalid `--effort` SHALL refuse even when a tier or profile would supply a valid value. Refusal SHALL occur before session/worktree creation, settings/record writes or tmux creation. Without `--effort`, Codex behaviour SHALL be unchanged. Whether a given model supports a level SHALL remain the runtime's decision, and a runtime rejection SHALL follow the existing failed-start lifecycle without a retry at another effort.

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
