## ADDED Requirements

### Requirement: Installer advertises the canonical Agentsembli SpecForge source

CLI help, readiness output, documentation templates, update instructions, and
package metadata SHALL use `JoMe92/agentsembli-specforge` as the canonical
repository source while retaining `specforge` as the compatible command name.

#### Scenario: User requests CLI help

- **WHEN** the packaged CLI prints installation or update guidance
- **THEN** every maintained GitHub command names `JoMe92/agentsembli-specforge` and the invoked binary remains `specforge`

### Requirement: Cross-repository update preserves target-owned state

Updating an installation originally obtained from `JoMe92/specforge` with a
tagged `JoMe92/agentsembli-specforge` release SHALL preserve the same target-owned
files and settings as an ordinary update.

#### Scenario: Legacy source installation updates from successor

- **WHEN** a throwaway repository installed from the preceding legacy tag updates using the renamed release
- **THEN** OpenSpec changes, Beads data, project configuration, custom documentation, and unrelated Claude, Codex, and Pi settings remain unchanged
