## ADDED Requirements

### Requirement: Public installation guidance matches installer behavior

The CLI help, README, and installation reference SHALL agree on prerequisites,
supported platforms, files created or overwritten, default Beads
initialization, every option, version pinning, Git-hook interaction, systemd
and non-systemd operation, Claude/Codex/Pi payloads, and readiness outcomes.
Examples SHALL use portable paths and the current stable tag or a clearly
defined version placeholder.

#### Scenario: Documentation and CLI are compared

- **WHEN** the documented flags, payload table, prerequisites, and post-install steps are checked against a fresh install and CLI help
- **THEN** every supported option and written path is represented accurately
- **AND** no instruction assumes the maintainer's home directory, private-repository authentication, or obsolete release tag

### Requirement: Installed user documentation is complete

The installer SHALL deliver every user guide referenced from installed
documentation, including the Claude, Codex, and Pi integration guidance. It
SHALL NOT install repository-internal research, conversation exports, or
historical acceptance reports as user documentation.

#### Scenario: An installed documentation link is followed

- **WHEN** a user follows any relative link from a document installed under `docs/nogging/`
- **THEN** its target is installed at the referenced path

### Requirement: Users can identify, update, roll back, and remove an installation

The CLI SHALL report its released version and the documentation SHALL provide
safe, explicit procedures for updating to a pinned release, rolling back to a
prior release, and removing Nogging-owned files and hook entries without
deleting target-owned OpenSpec changes, Beads data, configuration, or unrelated
agent settings.

#### Scenario: A user requests the installed tool version

- **WHEN** the version command or option is invoked
- **THEN** it prints the same semantic version recorded in the package

#### Scenario: A user removes Nogging

- **WHEN** the documented removal procedure is followed
- **THEN** Nogging-owned executables and injected configuration are removed or identified for removal
- **AND** target-owned planning and Beads state remain preserved

### Requirement: Platform support is explicit and test-backed

The installer SHALL declare the minimum supported versions of Node.js, Python,
Git, Bash, OpenSpec, Beads, and Dolt, plus which operating systems,
architectures, service managers, and agent CLIs are supported, experimental,
or unsupported. CI and acceptance SHALL exercise every combination claimed as
supported or explicitly document why a manual test supplies the evidence.

#### Scenario: A user checks compatibility before installation

- **WHEN** a user reads the compatibility documentation
- **THEN** they can determine whether their operating system, architecture, runtime versions, service manager, and chosen agent path are supported

