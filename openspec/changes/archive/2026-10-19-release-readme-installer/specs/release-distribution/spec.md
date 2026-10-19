## ADDED Requirements

### Requirement: Install pins follow the package version

Every pinned install reference in `README.md`, `docs/installation.md` and the
`NOGGING_TAG` pin in `scripts/bootstrap` SHALL equal `v` followed by the
`version` in `package.json`. A documented `<tag>` placeholder is allowed. An
install reference to `main` or `develop` is not. Tests SHALL derive the
expected tag from `package.json` rather than hard-coding a release. The
release procedure SHALL name every file that carries a pin.

#### Scenario: A release bump misses a pin

- **WHEN** `package.json` is bumped to a new version and one pinned reference still names the previous tag
- **THEN** the pin test fails and names the file and the stale tag

#### Scenario: A version bump needs no test edit

- **WHEN** a release bumps `package.json`, `package-lock.json` and every pinned reference together
- **THEN** every pin-checking test passes without being edited

### Requirement: The changelog structure guards semantic versioning

`CHANGELOG.md` SHALL keep exactly one `## [Unreleased]` section at the top.
Every released section SHALL be headed `## [X.Y.Z] - YYYY-MM-DD`, or the
release-candidate form, with versions strictly descending, and SHALL use
only Keep a Changelog subsection names. A released section that marks a
change `**BREAKING**` SHALL have a higher major version than the next older
released section. Each `**BREAKING**` entry SHALL name its migration step.

#### Scenario: A breaking change is released as a minor version

- **WHEN** a released section contains a `**BREAKING**` entry and shares its major version with the next older section
- **THEN** the changelog test fails and names that section

#### Scenario: Release preparation cuts the unreleased section

- **WHEN** release preparation moves `[Unreleased]` under a new version
- **THEN** that section carries the release date, a fresh empty `[Unreleased]` sits above it, and `scripts/release-check <version>` reports the changelog section present

### Requirement: Release preparation stops before the tag

Release preparation SHALL update the changelog, the package version and the
install pins in one commit with a Conventional `chore(release)` subject. It
SHALL NOT create or push a tag, create a GitHub Release, or publish
artifacts. Those steps SHALL remain a separate, explicit action after
`scripts/release-check <version>` passes on the committed state.

#### Scenario: Release preparation is merged

- **WHEN** the release-preparation commit is integrated into `develop`
- **THEN** `scripts/release-check <version>` reports every check OK and the tag as not yet existing
- **AND** no tag or GitHub Release for that version has been created by the preparation
