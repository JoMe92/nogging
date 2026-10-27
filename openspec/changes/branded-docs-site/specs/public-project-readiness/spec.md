## MODIFIED Requirements

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
