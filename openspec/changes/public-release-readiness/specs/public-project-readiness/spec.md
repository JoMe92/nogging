## Purpose

Defines the evidence and repository-facing contracts that make SpecForge safe,
understandable, supportable, and legally usable before its owner publishes the
repository to the public.

## ADDED Requirements

### Requirement: The repository has an explicit legal and project identity

The repository SHALL contain the full ISC license text matching its package
metadata, identify the copyright holder, document applicable third-party
licenses or generated content, and state that SpecForge is independent of the
vendors and projects whose tools it integrates. GitHub-facing metadata SHALL
provide a description, topics, support destination, and project status without
claiming an affiliation that does not exist.

#### Scenario: A prospective user evaluates reuse rights

- **WHEN** a prospective user inspects the repository root and package metadata
- **THEN** the same license is clearly identified in both places
- **AND** third-party attribution and non-affiliation information are available

### Requirement: The public identity preserves project independence and provenance

The repository SHALL continue to present **SpecForge** as the public project
name and SHALL explain its purpose without requiring a separate product website
or sibling application. It MAY identify **Agentsembli** as the provisional
working name for a wider ecosystem and **Agent Console** as an optional sibling,
but SHALL NOT present either as a prerequisite or finished commercial product.

The public README SHALL visibly credit Gas Town as a conceptual inspiration,
link to the upstream Gas Town and Beads projects, state that SpecForge is an
independent implementation, identify Beads as the only Gas Town component
currently adopted, and disclaim affiliation or endorsement. It SHALL NOT imply
that Gas Town runtime code or components are included.

#### Scenario: A reader evaluates the project's origin and product relationship

- **WHEN** a reader opens the public README without prior project context
- **THEN** SpecForge is understandable and installable as a standalone project
- **AND** Agentsembli is identified only as a provisional ecosystem working name
- **AND** Gas Town inspiration, Beads adoption, independent implementation, and
  non-affiliation are stated together with direct upstream links

### Requirement: Public users and contributors have complete entry-point documentation

The repository SHALL provide a user-first README, a copyable five-minute
quickstart, a documentation index, contribution guidance, a code of conduct, a
security policy, support expectations, issue templates, and a pull-request
template. The documentation SHALL distinguish user installation from
maintainer development and SHALL link to authoritative installation,
operations, recovery, security, and compatibility guidance.

#### Scenario: A new user starts without repository-specific knowledge

- **WHEN** a user opens the public repository for the first time
- **THEN** the README explains what SpecForge does, who it is for, its maturity and supported environments
- **AND** the user can follow a copyable path from prerequisites through a first successful readiness check
- **AND** no product website, renamed repository, or Agent Console installation
  is required to complete that path

#### Scenario: A contributor reports or fixes a problem

- **WHEN** a contributor opens the repository's contribution or issue guidance
- **THEN** it explains setup, workflow, tests, commit rules, responsible disclosure, and support boundaries

### Requirement: Publication data is audited before visibility changes

Every Git ref intended to remain reachable, Git history, tracked operational
state, packaged file, acceptance report, source note, and Beads/Dolt record
SHALL be scanned and manually reviewed for credentials, private URLs, personal
data, confidential conversations, and environment-specific information before
public release approval. Findings SHALL be removed, sanitized, deliberately
accepted, or recorded as blockers; a clean working-tree scan alone SHALL NOT
satisfy this requirement.

#### Scenario: The public-data audit completes

- **WHEN** public-release readiness is evaluated
- **THEN** a report identifies the refs and data stores that were scanned, the tools and rules used, and every accepted exception
- **AND** no unresolved credential or confidential-data finding remains

#### Scenario: Dolt data is included in the audit

- **WHEN** the remote advertises `refs/dolt/data` or a Dolt metadata branch
- **THEN** their Bead descriptions, notes, identities, and history are reviewed as public data

### Requirement: Security authority and trust boundaries are explicit

Documentation SHALL explain the permissions and residual risks of restricted,
trusted, and orchestrator modes; all installed hooks, agent instructions,
extensions, background services, network access, and destructive-command
floors; and the limits of those protections for Claude Code, Codex, and Pi.
Full-access and always-on operation SHALL be described as explicit opt-ins.

#### Scenario: A user evaluates trusted mode

- **WHEN** a user considers enabling trusted or orchestrator operation
- **THEN** the documentation identifies the additional authority, persistent processes, vendor-specific limitations, and safe disable procedure before presenting the enable command

### Requirement: Publication remains a manual owner decision

The project SHALL produce a final readiness report showing each legal,
privacy, documentation, security, compatibility, distribution, CI, and
acceptance gate as passed or blocked. Changing repository visibility SHALL NOT
be performed by the readiness workflow, an implementation Bead, or an agent;
the report SHALL end with a separate owner-only checklist for that action.

#### Scenario: All automated work is complete

- **WHEN** every implementation and verification Bead is closed
- **THEN** the repository remains private
- **AND** the final report gives the owner the exact manual checks required before changing visibility

#### Scenario: A readiness gate fails

- **WHEN** the report contains an unresolved blocker or unsigned acceptance report
- **THEN** it recommends keeping the repository private
- **AND** it does not present publication as approved
