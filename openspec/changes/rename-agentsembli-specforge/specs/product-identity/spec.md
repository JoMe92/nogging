## Purpose

Defines the public Agentsembli SpecForge identity and the compatibility and
owner-control boundaries for moving from the legacy SpecForge repository.

## ADDED Requirements

### Requirement: Agentsembli SpecForge is the canonical public identity

The project SHALL use **Agentsembli SpecForge** as its public display name and
`JoMe92/agentsembli-specforge` as its canonical repository. Current public
metadata, documentation, support and security routes, tagged installation
commands, and release assets SHALL resolve to that repository.

#### Scenario: A new user discovers the project

- **WHEN** a user reaches the canonical repository without prior context
- **THEN** the Agentsembli SpecForge purpose, installation, support, security, and provenance are complete and internally consistent

### Requirement: The first renamed release preserves installed identifiers

The first Agentsembli SpecForge release SHALL retain the `specforge` CLI,
`.specforge/` configuration and state root, `scripts/specforge` installed path,
`docs/specforge/` documentation path, generated `specforge-` service prefix,
and supported prompt-link aliases. A repository rename SHALL NOT rename or
delete target-owned OpenSpec, Beads, configuration, or unrelated agent state.

#### Scenario: Existing SpecForge installation updates

- **WHEN** an installation from the preceding `JoMe92/specforge` tag updates from the new repository
- **THEN** its existing command, configuration, OpenSpec, Beads, services, and unrelated settings remain usable without state migration

### Requirement: Legacy identity remains provenance, not an active destination

Historical references MAY identify the former `JoMe92/specforge` repository,
but maintained public entry points SHALL route to `JoMe92/agentsembli-specforge`.
The old repository SHALL remain private, archived, or otherwise unavailable for
public installation unless the owner explicitly approves a safe redirect.

#### Scenario: User follows an old installation instruction

- **WHEN** a user encounters a maintained transition notice for the old repository
- **THEN** it identifies Agentsembli SpecForge as the successor and gives a pinned new-repository command

### Requirement: Visibility and final identity acceptance remain human actions

Automation SHALL NOT make the new repository public or sign the final
acceptance report. Those actions SHALL require the Product Owner after all
privacy, security, migration, link, and release gates pass. While the repository
is private, `SECURITY.md` SHALL provide the applicable reporting instructions.
Because GitHub exposes Private Vulnerability Reporting only for public
repositories, the owner cutover SHALL enable and verify it immediately after
the visibility change and before signing final acceptance.

#### Scenario: Mechanical checks finish

- **WHEN** every automated rename and release check passes
- **THEN** the repository remains private and the acceptance report remains unsigned until the owner acts
- **AND** the owner checklist sequences public visibility, Private Vulnerability Reporting enablement and verification, then final sign-off
