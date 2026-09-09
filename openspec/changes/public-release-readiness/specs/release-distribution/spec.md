## Purpose

Defines a deterministic GitHub-based distribution and release process whose
contents, provenance, compatibility, and user-visible changes can be verified
before public users install SpecForge.

## ADDED Requirements

### Requirement: The initial public distribution is GitHub-only

The project SHALL identify tagged GitHub source installation as its supported
initial public distribution, SHALL recommend a concrete release tag rather
than an unpinned default branch, and SHALL prevent accidental npm-registry
publication. It SHALL disclose that the unscoped npm name `specforge` belongs
to another project and treat npm publication as out of scope for this change.

#### Scenario: A user chooses an installation source

- **WHEN** a user reads the public installation instructions
- **THEN** the primary command pins a released GitHub tag
- **AND** the documentation does not imply that this project owns the npm package named `specforge`

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

