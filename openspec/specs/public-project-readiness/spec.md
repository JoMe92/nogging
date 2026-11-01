# public-project-readiness Specification

## Purpose
Defines the evidence and repository-facing contracts that make Nogging safe,
understandable, supportable, and legally usable before its owner publishes the
repository to the public.

## Requirements

### Requirement: The repository has an explicit legal and project identity

The repository SHALL contain the full ISC license text matching its package
metadata, identify the copyright holder, document applicable third-party
licenses or generated content, and state that Nogging is independent of the
vendors and projects whose tools it integrates. For third-party material that
the package distributes under the MIT License, such as the OpenSpec and Beads
skill material under `.agents/skills/`, `THIRD_PARTY_NOTICES.md` SHALL carry
the full license text with the upstream copyright line and SHALL link the
current upstream repository. GitHub-facing metadata SHALL provide a
description, topics, support destination, and project status without claiming
an affiliation that does not exist.

#### Scenario: A prospective user evaluates reuse rights

- **WHEN** a prospective user inspects the repository root and package metadata
- **THEN** the same license is clearly identified in both places
- **AND** third-party attribution and non-affiliation information are available

#### Scenario: A redistributor checks the bundled skill licenses

- **WHEN** a redistributor reads `THIRD_PARTY_NOTICES.md`
- **THEN** it contains the MIT License text with `Copyright (c) 2024 OpenSpec Contributors` for the OpenSpec skills and `Copyright (c) 2025 Beads Contributors` for the Beads skill
- **AND** it links `https://github.com/Fission-AI/OpenSpec` and `https://github.com/gastownhall/beads`

#### Scenario: A notice loses its license text or points at the old Beads home

- **WHEN** `THIRD_PARTY_NOTICES.md` lacks either copyright line or the MIT permission sentence, or links `github.com/steveyegge/beads`
- **THEN** `scripts/legal.test.sh` fails and names the missing or stale item

### Requirement: The public identity preserves project independence and provenance

The repository SHALL continue to present **Nogging** as the public project
name and SHALL explain its purpose without requiring a separate product website
or sibling application. It MAY identify **Agent Console** as an optional
sibling, but SHALL NOT present it as a prerequisite.

The public README SHALL visibly credit Gas Town as a conceptual inspiration,
link to the upstream Gas Town and Beads projects, state that Nogging is an
independent implementation, identify Beads as the only Gas Town component
currently adopted, and disclaim affiliation or endorsement. It SHALL NOT imply
that Gas Town runtime code or components are included.

#### Scenario: A reader evaluates the project's origin and product relationship

- **WHEN** a reader opens the public README without prior project context
- **THEN** Nogging is understandable and installable as a standalone project
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
- **THEN** the README explains what Nogging does, who it is for, its maturity and supported environments
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

### Requirement: The README leads a newcomer from purpose to daily use before reference material

`README.md` SHALL present, in this order:

1. a statement of what Nogging is, in no more than three sentences, before
   any section heading;
2. a Quick Guide of at most eight numbered steps that goes from no
   installation to a closed first task, each step carrying a copyable
   command;
3. installation, first for a fresh machine through the pinned
   `scripts/bootstrap`, then for an existing repository through the pinned
   `npx … init`;
4. day-to-day use, covering, in order, planning a change, launching a Lead
   Agent, watching and steering sessions, and closing work out.

Safety, project status, supported environments, concepts, architecture, the
documentation index, maintainer development and provenance SHALL follow day-to-day use or
be linked to `docs/`. The README SHALL keep the rule that install commands
are pinned to a released tag and never to `main` or `develop`. It SHALL
link the security and threat model before any command that grants full
access.
The README SHALL present Nogging as a public release and SHALL NOT describe
it as a pre-public release candidate. Its project-status section SHALL advise
keeping target repositories where agents run with full access private, and
reading the safety warning before enabling `--full-access` or background
services.

#### Scenario: A newcomer reads the README top to bottom

- **WHEN** a newcomer reads `README.md` from the top
- **THEN** they meet the purpose, the Quick Guide, installation and day-to-day use before any concept, architecture or maintainer section
- **AND** they can install, check readiness, plan a change and launch a Lead by copying commands from the Quick Guide

#### Scenario: The README states the public status

- **WHEN** a reader opens the project-status section of `README.md`
- **THEN** the README does not call Nogging a pre-public release candidate
- **AND** the section advises keeping repositories where agents run with full access private and reading the safety warning before enabling `--full-access` or background services

#### Scenario: The order is checked mechanically

- **WHEN** the README structure test runs
- **THEN** it fails if a required section is missing or out of order, if the intro exceeds three sentences, if the Quick Guide exceeds eight steps, or if an install URL is not pinned to a released tag

#### Scenario: Full access is reached only after the safety link

- **WHEN** the README first shows a `session launch` command with `--full-access`
- **THEN** a link to the security and threat model appears earlier in the README
