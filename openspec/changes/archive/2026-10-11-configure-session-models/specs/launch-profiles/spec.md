## ADDED Requirements

### Requirement: Session model selection has explicit precedence and provenance

Session launch SHALL accept an optional --model override and optional agent-appropriate profile model; the override SHALL take precedence over the profile, followed by the native runtime default. Codex profiles SHALL optionally accept a supported model_reasoning_effort. Omitted keys SHALL preserve existing behavior. The session record and list SHALL show the requested model and selection source, or runtime-default when not specified, without modifying user-global settings.

#### Scenario: Override a profile model

- **WHEN** a valid profile model and a different --model are supplied
- **THEN** the override is passed to the runtime and recorded with source launch

#### Scenario: Legacy profile

- **WHEN** no model or reasoning setting is provided
- **THEN** native defaults remain effective and the listing honestly displays runtime-default

#### Scenario: Invalid reasoning setting

- **WHEN** an unsupported reasoning effort is configured
- **THEN** launch refuses before tmux or record creation
