## ADDED Requirements

### Requirement: A cloud session can bootstrap Beads and hooks via an opt-in hook template

Nogging SHALL ship an optional `SessionStart` hook template that, only when
`CLAUDE_CODE_REMOTE` is `"true"`, installs the pinned `bd`/Dolt versions, sets
`core.hooksPath`, and runs `bd bootstrap`. Outside a cloud session the
template SHALL exit without effect. The template SHALL NOT be wired into a
consumer's `.claude/settings.json` automatically by the installer — a
project opts in deliberately.

#### Scenario: The template is inert locally

- **WHEN** the hook template runs with `CLAUDE_CODE_REMOTE` unset or not `"true"`
- **THEN** it exits without installing anything or changing `core.hooksPath`

#### Scenario: The template bootstraps a fresh cloud container

- **WHEN** the hook template runs with `CLAUDE_CODE_REMOTE=true` in a fresh
  cloud container
- **THEN** the pinned `bd`/Dolt versions are installed
- **AND** `core.hooksPath` is set
- **AND** `bd bootstrap` has run, so `bd ready` works afterward

#### Scenario: The installer does not wire the hook in automatically

- **WHEN** the installer runs `init` or `update`
- **THEN** it does not add the cloud `SessionStart` hook to
  `.claude/settings.json` on its own

### Requirement: doctor reports cloud-session environment readiness

`scripts/nogg doctor` SHALL detect a cloud session via `CLAUDE_CODE_REMOTE`
and, when running in one, report as a NOTE whether `core.hooksPath` is set
and whether `bd` is on `PATH`. This check SHALL NOT fail `doctor` or change
its exit code, and SHALL print nothing when not running in a cloud session.

#### Scenario: A cloud session's readiness is reported

- **WHEN** `doctor` runs with `CLAUDE_CODE_REMOTE=true`
- **THEN** it prints a NOTE stating whether `core.hooksPath` is set and
  whether `bd` is available
- **AND** `doctor`'s exit code is unchanged regardless of what it finds

#### Scenario: The check is silent locally

- **WHEN** `doctor` runs with `CLAUDE_CODE_REMOTE` unset or not `"true"`
- **THEN** it prints no cloud-session readiness NOTE
