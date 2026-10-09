## ADDED Requirements

### Requirement: Every installed session runtime helper is refreshed together

Nogging init and update SHALL install executable session launch and log-writer helpers from the same distribution as scripts/nogg. Update SHALL repair missing and stale helpers while preserving target-owned planning, Beads and unrelated configuration; remove SHALL remove only Nogging-owned helpers.

#### Scenario: Repair a partial older installation

- **WHEN** update runs in a repository missing either helper
- **THEN** both current executable helpers are installed and target-owned files are unchanged

#### Scenario: Consumer test portability

- **WHEN** the installed test runner runs with minimal supported configuration
- **THEN** tests use local fixtures and do not require Nogging maintainer changes or explicitly present defaulted keys
