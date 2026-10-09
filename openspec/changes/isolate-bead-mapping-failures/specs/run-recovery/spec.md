## ADDED Requirements

### Requirement: Partial reconciliation is visibly degraded

A partial sync SHALL expose affected changes, Bead IDs and reasons with a documented nonzero degraded result, SHALL preserve the last completely successful timestamp, and SHALL let doctor distinguish last complete success from last partial pass.

#### Scenario: Partial pass after an earlier success

- **WHEN** only some valid changes reconcile
- **THEN** doctor shows skipped work and both timestamps without describing the whole repository as healthy
