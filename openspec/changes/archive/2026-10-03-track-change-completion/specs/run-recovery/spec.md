## ADDED Requirements

### Requirement: doctor reports a change ready to archive

`doctor` SHALL report, as a NOTE, every live (non-archived) change under
`openspec/changes/` whose every mapped Bead is closed, determined using the
same closed-inclusive Beads enumeration the sync and materialize mechanisms
use rather than a closed-excluding listing. This NOTE SHALL NOT fail
`doctor` or change its exit code, matching every other advisory NOTE `doctor`
already prints.

#### Scenario: A fully-closed change is surfaced

- **WHEN** every Bead mapped to a live change's tasks is closed
- **AND** `doctor` runs
- **THEN** it prints a NOTE naming that change as ready to archive
- **AND** `doctor`'s exit code is unchanged

#### Scenario: A partially-closed change is not surfaced

- **WHEN** a live change has at least one open or in-progress mapped Bead
- **AND** `doctor` runs
- **THEN** it does not report that change as ready to archive
