## MODIFIED Requirements

### Requirement: Session model selection has explicit precedence and provenance

Session launch SHALL accept an optional --model override and optional agent-appropriate profile model; the override SHALL take precedence over the profile, followed by the native runtime default. Codex profiles SHALL optionally accept a supported model_reasoning_effort. Claude profiles SHALL optionally accept an effort setting with the Claude-specific selection and validation requirements below. Omitted keys SHALL preserve existing behavior. The session record and list SHALL show the requested model and selection source, or runtime-default when not specified, without modifying user-global settings.

#### Scenario: Override a profile model

- **WHEN** a valid profile model and a different --model are supplied
- **THEN** the override is passed to the runtime and recorded with source launch

#### Scenario: Legacy profile

- **WHEN** no model or reasoning setting is provided
- **THEN** native defaults remain effective and the listing honestly displays runtime-default

#### Scenario: Invalid reasoning setting

- **WHEN** an unsupported reasoning effort is configured
- **THEN** launch refuses before tmux or record creation


## ADDED Requirements

### Requirement: Claude effort has validated session-scoped precedence

Claude JSON launch profiles SHALL accept optional `effort`, and `scripts/nogg session launch` SHALL accept `--effort <level>` only for the resolved Claude agent. Allowed values SHALL be exact strings `low`, `medium`, `high`, `xhigh`, and `max`. Launch SHALL validate both provided inputs, then select launch override over profile effort over native runtime behavior. A present invalid profile value SHALL refuse even when overridden. Omission SHALL emit no effort flag and preserve native behavior. `model_reasoning_effort` SHALL remain Codex-only; `effort` SHALL be rejected in non-Claude profiles, and `--effort` SHALL refuse for non-Claude launches. Refusal SHALL occur before session/worktree creation, settings/record writes or tmux creation. Model selection SHALL remain independent.

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

- **WHEN** --effort targets Codex, Pi or Antigravity, a non-Claude profile contains effort, or a Claude profile contains model_reasoning_effort
- **THEN** launch refuses before session creation rather than dropping or translating the setting
- **AND** valid existing Codex model_reasoning_effort behavior remains unchanged

### Requirement: Claude effort reaches the native process without changing authority or persistent configuration

A selected Claude effort SHALL reach the Claude process as separate `--effort` and level argv elements on cold launches and exact-conversation resumes. Nogging SHALL NOT write effort to user-global config, change the source profile, or change authority, fencing, prompt, model or conversation selection because effort was supplied. The Nogging profile key SHALL NOT leak into generated Claude settings. A stale helper unable to guarantee Claude effort forwarding SHALL cause preflight refusal with an update remedy before creating a session. Runtime rejection SHALL retain the existing failed-start diagnostics without silently retrying at another effort.

#### Scenario: Native argv on launch and resume

- **WHEN** Claude launches cold or resumes an exact conversation with effort xhigh
- **THEN** its native argv contains exactly one --effort option followed by xhigh
- **AND** all unrelated launch arguments and permission boundaries are preserved

#### Scenario: Legacy helper cannot drop effort

- **WHEN** effort is requested and the installed helper lacks the Claude effort-forwarding capability
- **THEN** launch refuses before session creation and instructs the operator to update Nogging

#### Scenario: Global and profile state is preserved

- **WHEN** launches select each supported Claude effort including max
- **THEN** source profiles and existing user-global configuration remain byte-for-byte unchanged by Nogging
- **AND** the generated settings contain no Nogging effort key

#### Scenario: Native rejection stays visible

- **WHEN** the Claude runtime rejects an effort or model combination
- **THEN** the session follows the existing failed-start lifecycle with scrubbed diagnostics
- **AND** Nogging does not retry with the effort omitted or changed

### Requirement: Requested reasoning effort and provenance are durable and visible

New Claude and Codex session records SHALL contain `reasoning_effort` and `reasoning_effort_source`. Source SHALL be `launch`, `profile`, or `runtime-default`; absent effort SHALL be null with source runtime-default. Codex profile effort SHALL use source profile. Session list SHALL show the requested level and source, or effort=runtime-default when unspecified in new Claude/Codex records. Existing model fields SHALL remain intact. Old records without effort-source SHALL remain readable: present effort SHALL show unknown provenance, and absent effort SHALL retain the prior display. Other agents' display SHALL remain unchanged. These fields SHALL describe the launch request, not imply observation of later interactive changes or runtime-resolved defaults.

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
