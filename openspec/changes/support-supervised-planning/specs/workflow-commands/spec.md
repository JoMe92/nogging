## ADDED Requirements

### Requirement: Orchestration launches use a scoped supported permission path

Nogging SHALL document scoped supervised session commands for orchestrator child launches, preserve unrelated user permissions, and report missing permission prerequisites or unsupported classifier combinations through doctor. It SHALL NOT fall back to direct unsupervised agent invocation, silently change global permission modes, or install persistent services to make a launch succeed.

#### Scenario: Missing launch permissions

- **WHEN** an orchestrator lacks the supported launch permission setup
- **THEN** doctor names the missing setup and the deliberate supported remedy

#### Scenario: Permission denial

- **WHEN** a supervised child launch is denied
- **THEN** the caller reports the denial and does not create an unprofiled child
