## Purpose

Defines a stable public identity for SpecForge while keeping the wider
Agentsembli concept explicitly provisional and preserving provenance.

## ADDED Requirements

### Requirement: SpecForge remains the standalone public project identity

The project SHALL use **SpecForge** as its public display name and retain its
existing repository, command, installer, service, and package identifiers.
Installation and use SHALL NOT require a website, renamed repository, claimed
umbrella-brand property, or Agent Console.

#### Scenario: A new user discovers the project

- **WHEN** the user reaches the repository without ecosystem context
- **THEN** SpecForge's purpose, installation, and support routes are complete
- **AND** no rename or external brand property is required

### Requirement: Agentsembli remains provisional and non-blocking

Public documentation MAY describe **Agentsembli** as the provisional working
name for a possible ecosystem containing SpecForge and optional Agent Console.
It SHALL NOT present Agentsembli as registered, claimed, released, required, or
a finished commercial product.

#### Scenario: Ecosystem language is shown

- **WHEN** Agentsembli appears in current public material
- **THEN** it is identified as a provisional working name
- **AND** SpecForge remains independently understandable and usable

### Requirement: Inspiration and implementation boundaries are explicit

The public identity statement SHALL link to Gas Town and Beads, credit Gas Town
as conceptual inspiration, identify Beads as the only component currently
adopted from that ecosystem, and state that SpecForge is independently
implemented and unaffiliated. It SHALL NOT imply inclusion of Gas Town runtime
components, compatibility, endorsement, or shared ownership.

#### Scenario: A reader evaluates provenance

- **WHEN** the reader reviews the README or identity statement
- **THEN** inspiration, adopted dependency, independent implementation, and
  non-affiliation are presented together

### Requirement: Identity facts have one testable source

The repository SHALL contain a concise identity document recording the
canonical name, provisional ecosystem status, stable identifiers, destinations,
optional sibling relationship, concept, and provenance. Automated checks SHALL
detect contradictions in designated current public entry points.

#### Scenario: Public identity surfaces are audited

- **WHEN** current public entry points are compared with the identity document
- **THEN** SpecForge remains canonical, Agentsembli remains provisional, and
  existing technical identifiers remain unchanged

### Requirement: Future umbrella branding is a separate owner decision

Claims for a future umbrella brand SHALL remain owner-controlled and out of
scope. Reopening that work SHALL require fresh research, appropriate legal
review, explicit owner action, and a separately planned migration if needed.

#### Scenario: A future name is considered

- **WHEN** the owner later considers commercializing or renaming the ecosystem
- **THEN** current observations are not treated as reservations or clearance
- **AND** the current public release remains valid without that change

### Requirement: Identity acceptance is part of release acceptance

The public release SHALL verify identity wording, unchanged installation
identifiers, attribution links, and absence of an Agentsembli ownership
dependency. Final acceptance SHALL retain the human sign-off required by
public-release readiness.

#### Scenario: Identity checks pass mechanically

- **WHEN** automated checks confirm every identity requirement
- **THEN** the identity portion is mechanically complete
- **AND** it does not substitute for human release sign-off
