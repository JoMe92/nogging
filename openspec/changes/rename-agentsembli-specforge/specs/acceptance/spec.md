## ADDED Requirements

### Requirement: Rename acceptance validates the real new repository

Before public launch, acceptance SHALL use a fresh clone and an exact release
candidate tag from `JoMe92/agentsembli-specforge`. It SHALL cover clean install,
legacy-source upgrade, rollback, uninstall preservation, supported Claude/Codex/Pi
paths, canonical links, repository metadata, and absence of forbidden history.

#### Scenario: Rename candidate passes mechanically

- **WHEN** the full acceptance procedure runs against the private candidate
- **THEN** every automated identity, lifecycle, agent-path, history, package, and link check passes with recorded evidence

### Requirement: Public launch requires later human sign-off

The rename acceptance report SHALL be committed unsigned. Agent automation
SHALL NOT change repository visibility or fill its `Signed-off-by:` field.

#### Scenario: Candidate is mechanically ready

- **WHEN** all automated acceptance checks pass but the owner has not signed
- **THEN** Agentsembli SpecForge remains private and is not reported as publicly accepted
