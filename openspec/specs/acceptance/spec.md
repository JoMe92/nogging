# acceptance Specification

## Purpose
TBD - created by archiving change end-to-end-acceptance. Update Purpose after archive.

## Requirements

### Requirement: SpecForge provides a reproducible end-to-end acceptance procedure

SpecForge SHALL provide a documented acceptance procedure that runs from an
empty git repository through install, planning, materialization, a simulated
execution, mechanical sync, and discovery review. Every step SHALL be marked as
either mechanical (no LLM, scriptable) or agent-driven (guided, manual), and
SHALL state its prerequisites and its expected observable outcome. The
mechanical steps SHALL be reproducible by a single command.

#### Scenario: The runbook covers the full chain

- **WHEN** a person follows `docs/acceptance.md` from the start
- **THEN** the procedure takes them from an empty repository to a completed acceptance report
- **AND** each step is marked mechanical or agent-driven
- **AND** each step states what output or state proves it passed

#### Scenario: The mechanical steps run from one command

- **WHEN** the mechanical acceptance harness is run
- **THEN** it performs the mechanical steps in the same order as the runbook
- **AND** it reports which runbook steps it covered

### Requirement: A clean install reaches readiness

The acceptance procedure SHALL verify that installing SpecForge into a fresh git
repository leaves it ready to plan. With the Beads backend available, the
readiness verdict SHALL report that SpecForge is ready and `doctor` SHALL exit
clean. Without the backend, the verdict SHALL name the uninitialized tracker as
the outstanding gap rather than reporting ready.

#### Scenario: Fresh install with a backend reports ready

- **WHEN** SpecForge is installed into a fresh repository and the Beads backend is reachable
- **THEN** the readiness verdict states that SpecForge is ready
- **AND** `scripts/specforge doctor` exits without failures

#### Scenario: Fresh install without a backend names the gap

- **WHEN** SpecForge is installed into a fresh repository with no Beads backend
- **THEN** the readiness verdict names the uninitialized tracker as the outstanding gap
- **AND** the verdict does not claim the repository is ready

### Requirement: The example change round-trips OpenSpec to Beads to execution to sync

The acceptance procedure SHALL carry a canned example change through
materialization and a simulated execution. Materializing the example SHALL
create exactly one Bead per example task. Closing one example Bead and running
the mechanical sync SHALL tick that task's checkbox and append exactly one
execution-log entry for the closure. Running sync again with no further change
SHALL make no changes.

#### Scenario: Materialize creates one Bead per task

- **WHEN** the acceptance procedure materializes the canned example change
- **THEN** one Bead is created for each task in the example's `tasks.md`

#### Scenario: A closed example Bead is mirrored once

- **WHEN** one example Bead is closed and the mechanical sync runs
- **THEN** the mapped task in the example's `tasks.md` is checked
- **AND** exactly one execution-log entry is appended for that closure

#### Scenario: Re-running sync is idempotent

- **WHEN** the mechanical sync runs again after the example closure was already mirrored
- **THEN** it reports that it made no changes
- **AND** the example change files have no further modification

### Requirement: Each acceptance run is recorded in a signed report

Completing an acceptance run SHALL produce a dated report stored under
`docs/acceptance/`. The report SHALL record the toolkit version and git commit,
the pass / fail / skipped result and a note for each runbook step, any
deviations from the runbook, and every discovery filed during the run with its
Bead ID. The report SHALL carry a human sign-off line that is left blank until a
person completes it. A change SHALL NOT be considered accepted until a signed
report exists.

#### Scenario: A completed run yields a report

- **WHEN** an acceptance run finishes
- **THEN** a dated report exists under `docs/acceptance/`
- **AND** it records a result and a note for every runbook step
- **AND** it lists the Bead ID of every discovery filed during the run

#### Scenario: Sign-off is a separate human action

- **WHEN** an acceptance report is first committed
- **THEN** its sign-off line is blank
- **AND** the report is marked accepted only by a later commit from a person completing that line

### Requirement: The mechanical subset runs unattended in CI

The mechanical subset of the acceptance procedure SHALL run in CI on every push
and pull request, with no LLM, no Beads backend, and no human input. It SHALL
fail the build if install, validate, materialize, or the sync round-trip
regresses.

#### Scenario: CI runs the mechanical subset

- **WHEN** CI runs for a push or pull request
- **THEN** the mechanical acceptance subset executes without a Beads backend or human input

#### Scenario: A regression fails the build

- **WHEN** a change breaks install, validation, materialization, or the sync round-trip
- **THEN** the mechanical acceptance subset fails
- **AND** the CI build is marked failed

### Requirement: Rename acceptance validates the real new repository

Before public launch, acceptance SHALL use a fresh clone and an exact release
candidate tag from `JoMe92/agentsembli-specforge`. It SHALL cover clean install,
legacy-source upgrade, rollback, uninstall preservation, supported Claude/Codex/Pi
paths, canonical links, repository metadata, and absence of forbidden history.

#### Scenario: Rename candidate passes mechanically

- **WHEN** the full acceptance procedure runs against the private candidate
- **THEN** every automated identity, lifecycle, agent-path, history, package, and link check passes with recorded evidence

### Requirement: Public launch requires later human sign-off

The rename acceptance report SHALL be committed unsigned. Agent automation
SHALL NOT change repository visibility or fill its `Signed-off-by:` field. The
pre-launch report SHALL verify the private-phase `SECURITY.md` route and record
Private Vulnerability Reporting as an owner cutover check that can pass only
after the repository becomes public.

#### Scenario: Candidate is mechanically ready

- **WHEN** all automated acceptance checks pass but the owner has not signed
- **THEN** Agentsembli SpecForge remains private and is not reported as publicly accepted

#### Scenario: Owner completes the public cutover

- **WHEN** the owner makes the validated repository public
- **THEN** the owner immediately enables and verifies Private Vulnerability Reporting before completing `Signed-off-by:`
