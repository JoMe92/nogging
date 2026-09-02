# run-hygiene Specification

## Purpose
TBD - created by archiving change harden-archive-and-records. Update Purpose after archive.

## Requirements

### Requirement: The invariant audit tolerates archived changes

`scripts/specforge validate` SHALL resolve a mapped Bead whose task belongs to
an archived change (a directory under `openspec/changes/archive/`) instead of
reporting it as mapping a missing task or a disagreeing change label. It SHALL
derive the change name from the archived directory by removing a leading
date prefix. `scripts/specforge materialize` and `scripts/specforge sync` SHALL
continue to act only on live changes and SHALL NOT read archived directories.

#### Scenario: A completed change is archived without breaking the audit

- **WHEN** a change with closed mapped Beads is moved under `openspec/changes/archive/`
- **AND** `scripts/specforge validate` runs
- **THEN** it reports no failures
- **AND** `scripts/specforge sync` reports no changes

#### Scenario: Archived task IDs do not count as duplicates

- **WHEN** a task ID appears both in a live change's `tasks.md` and in an archived change's `tasks.md`
- **THEN** the audit does not report a duplicate task ID

#### Scenario: Materialize and sync ignore archived changes

- **WHEN** an archived change directory exists under `openspec/changes/archive/`
- **THEN** `scripts/specforge materialize` and `scripts/specforge sync` do not create Beads for, or write files into, that archived change

### Requirement: Session enumeration ignores non-record files

`scripts/specforge` SHALL enumerate session records from
`.specforge/state/sessions/` in a way that excludes the per-session
effective-settings file and any other file that is not a session record.
`session list`, `session cleanup`, and the launch name-collision guard SHALL all
use this enumeration.

#### Scenario: The effective-settings file is not listed as a session

- **WHEN** a `<name>.settings.json` file exists beside a real `<name>.json` record
- **AND** `session list` runs
- **THEN** only real sessions are listed
- **AND** no row with an unknown or empty state is shown

#### Scenario: Cleanup is not fooled by the settings file

- **WHEN** no real session record is in an active state
- **AND** a `<name>.settings.json` file is present
- **AND** `session cleanup` runs with no name
- **THEN** it treats the set of active sessions as empty and stops the tmux server

### Requirement: Every launch-floor rule is a valid permission rule

Every entry in the launch command floor SHALL be a syntactically valid Claude
Code permission rule — no entry with empty or nested parentheses. A launched
session's effective settings SHALL contain every floor entry verbatim.

#### Scenario: The floor has no malformed entry

- **WHEN** the launch command floor is inspected
- **THEN** no entry has empty or nested parentheses
- **AND** each entry matches the shape of a valid `Bash(...)`, bare `Bash`, or `WebFetch` rule

#### Scenario: The floor reaches the launched session

- **WHEN** a session is launched under any profile
- **THEN** its effective-settings file contains every floor entry
