## Purpose

Defines a distinctive, evidence-backed public identity and a controlled rename
that preserves user compatibility, provenance, and owner authority over claims.

## ADDED Requirements

### Requirement: The product concept is stable before the name is selected

The project SHALL describe itself as a local-first delivery system that carries
approved intent through executable work to verifiable evidence. The concept
SHALL remain vendor-neutral and SHALL distinguish the product from a generic
specification generator, task tracker, coding agent, or CI service.

#### Scenario: A candidate name is evaluated

- **WHEN** a candidate name is reviewed
- **THEN** reviewers can judge whether it represents the documented concept
- **AND** the description does not imply ownership of or affiliation with an integrated tool

### Requirement: Name selection uses dated collision evidence

Before a canonical name is adopted, the project SHALL record a dated search of
relevant search engines, source hosts, package registries, domain registries,
social or organization handles, and official trademark databases in intended
markets. The record SHALL distinguish an observed absence from legal clearance
and SHALL list known collisions and residual uncertainty.

#### Scenario: A namespace appears available

- **WHEN** a registry returns no record for a candidate
- **THEN** the result is recorded with registry, exact spelling, date and scope
- **AND** it is described as a point-in-time observation rather than guaranteed availability

#### Scenario: A confusing collision is found

- **WHEN** an active product, package, repository or mark has a confusingly similar name
- **THEN** the candidate is rejected or escalated for explicit legal review
- **AND** implementation does not silently proceed under that candidate

### Requirement: Claims and final selection remain owner-controlled

Registering domains, package namespaces, accounts or marks and choosing the
canonical name SHALL require an explicit Product Owner action. Automation MAY
verify the resulting ownership but SHALL NOT purchase, register, transfer or
represent legal clearance on the owner's behalf.

#### Scenario: Research recommends a candidate

- **WHEN** automated and manual availability checks favor one candidate
- **THEN** the change remains blocked until the Product Owner records the final choice and claims the required properties

### Requirement: The canonical identity is internally consistent

After owner approval, the canonical display name, command name, package scope,
repository location, domains, support/security contacts and concise concept
statement SHALL be recorded once in an identity manifest and used consistently
across user-facing surfaces.

#### Scenario: Public identity surfaces are audited

- **WHEN** package metadata, CLI output, installed files, documentation, GitHub metadata and release assets are compared
- **THEN** they resolve to the identity manifest without stale primary branding

### Requirement: A rename preserves compatibility and provenance

A rename SHALL document old-to-new mapping, preserve release and contribution
history, provide redirects or compatibility aliases where technically possible,
and give users tested migration and rollback instructions. Historical evidence
SHALL NOT be rewritten merely to replace the old product name.

#### Scenario: An existing user upgrades across the rename

- **WHEN** a supported installation using the old name updates to the first release under the new name
- **THEN** its OpenSpec, Beads, configuration and project-owned work remain intact
- **AND** the user receives an actionable deprecation or migration message

#### Scenario: The rename is rolled back

- **WHEN** acceptance fails before public cutover
- **THEN** repository code and metadata can return to the prior identity without losing user state or claimed-property ownership records

### Requirement: Release approval verifies ownership and discoverability

The renamed product SHALL NOT be approved for public release until ownership of
required properties is verified, primary links resolve securely, old public
entry points route to the transition notice where possible, and a fresh user
can find and install the intended project without confusing it with a collision.

#### Scenario: Identity acceptance runs

- **WHEN** the release candidate is evaluated
- **THEN** the report includes evidence for owned properties, redirects, package/repository identity, migration, rollback and collision-free discovery
- **AND** human sign-off remains required
