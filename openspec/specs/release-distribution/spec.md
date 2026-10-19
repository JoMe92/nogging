# release-distribution Specification

## Purpose

Defines how the sanitized project history is transferred and released from the
new GitHub-only repository without carrying private legacy refs or artifacts.

## Requirements

### Requirement: The new repository starts from the sanitized history

The canonical repository SHALL receive only the verified rewritten branches and
tags. It SHALL NOT receive legacy pull refs, Dolt refs, `.beads/interactions.jsonl`,
internal source notes, old acceptance history, generated host units, bytecode,
maintainer-local paths, credential material, or private/local commit identities.

#### Scenario: Clean repository is populated

- **WHEN** the sanitized mirror is pushed to the newly created private repository
- **THEN** a fresh mirror clone exposes only approved heads and tags and every privacy and forbidden-artifact scan passes

### Requirement: GitHub-only distribution uses the new repository

The package SHALL remain blocked from npm-registry publication. Installation,
update, rollback, changelog, checksums, release notes, and post-release smoke
tests SHALL use an exact tag from `JoMe92/agentsembli-specforge`.

#### Scenario: Tagged installation succeeds

- **WHEN** a user runs the documented `npx github:JoMe92/agentsembli-specforge#<tag>` command
- **THEN** the expected CLI and payload install successfully without contacting the npm registry for this package

### Requirement: A recoverable private backup precedes cutover

Before destructive replacement, a complete private mirror and verified bundle
of the legacy repository SHALL exist with a checksum and restoration notes.
The backup SHALL remain outside both public Git history and package contents.

#### Scenario: Cutover must be rolled back

- **WHEN** validation fails before public visibility changes
- **THEN** the owner can restore the legacy private repository from the recorded backup without losing its original refs

### Requirement: The initial public distribution is GitHub-only

The project SHALL identify tagged GitHub source installation as its supported
initial public distribution, SHALL recommend a concrete release tag rather
than an unpinned default branch, and SHALL prevent accidental npm-registry
publication. It SHALL treat npm publication, including verifying whether the
desired unscoped `nogg`/`nogging` package name is available, as out of scope
for this change.

#### Scenario: A user chooses an installation source

- **WHEN** a user reads the public installation instructions
- **THEN** the primary command pins a released GitHub tag
- **AND** the documentation does not imply that this project has published or claimed any npm package name

#### Scenario: Accidental npm publication is attempted

- **WHEN** a maintainer runs the normal npm publication command from this package
- **THEN** package metadata prevents the package from being published to the registry

### Requirement: The packaged payload is minimal and deterministic

The release package SHALL contain only documented runtime payloads and selected
user documentation. It SHALL exclude bytecode, caches, generated local units,
private or internal source notes, repository acceptance history, credentials,
and development-only artifacts. CI SHALL build from a clean checkout and fail
when forbidden paths enter the package or required payloads are absent.

#### Scenario: A clean release package is inspected

- **WHEN** CI performs the package-content check from a clean checkout
- **THEN** all required Claude, Codex, Pi, OpenSpec, script, template, and user-documentation files are present
- **AND** no cache, bytecode, internal source note, host-specific unit, or undeclared file is present

#### Scenario: A local generated file exists

- **WHEN** a developer has a generated file such as `__pycache__/*.pyc` under an otherwise included directory
- **THEN** it is absent from the package

### Requirement: Public releases are reproducible and traceable

Every public release SHALL derive from a validated commit on `main`, update the
declared version and changelog, create a verifiable annotated tag, publish a
GitHub Release with installation and upgrade notes, attach checksums and an
SBOM when release artifacts are produced, and run a smoke install using the
exact published tag. The release procedure SHALL be documented and guarded by
CI or a checklist that cannot report success before each required result exists.

#### Scenario: A release succeeds

- **WHEN** a maintainer publishes a public release
- **THEN** its version, changelog, tag, GitHub Release, source commit, checksums or documented not-applicable result, and tagged-install evidence agree

#### Scenario: Tagged installation fails

- **WHEN** the post-release smoke test cannot install and reach the expected readiness state from the published tag
- **THEN** the release is reported as failed and remediation or replacement-release instructions are recorded

### Requirement: CI enforces public release quality

CI SHALL use least-privilege token permissions, pin third-party actions to
immutable revisions, scan dependencies and repository contents for known
security issues, validate documentation links and package contents, and test
the supported Node, Python, architecture, and operating-system matrix or mark
unsupported combinations explicitly.

#### Scenario: A pull request changes distributed code or documentation

- **WHEN** CI evaluates the pull request
- **THEN** functional, acceptance, package-content, documentation, dependency, and security checks run with read-only permissions unless a job documents a narrower required write permission

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
