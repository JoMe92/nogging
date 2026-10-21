# test-isolation Specification

## Purpose
Ensure planning and OpenSpec-guard regression tests can run directly from a
supervised session without inheriting operator authority or contacting live state.

## Requirements

### Requirement: Planning and guard test entry points isolate inherited context generically

Every script test that executes planning commands or OpenSpec guards, directly
or through another harness, SHALL remove all inherited exported `NOGG_*`
variables and `NOGGING_ROOT` before fixture setup, module imports or child
processes. The repository test runner SHALL apply the same generic rule.
Fixtures SHALL explicitly supply any required session context after cleanup.
Unrelated environment settings and the invoking parent's context SHALL remain
unchanged. Production authority and guard enforcement SHALL remain unchanged.

#### Scenario: Direct execution under a supervised session

- **WHEN** an affected test is directly invoked with role-only, name-only or combined session context, fence markers, invalid roots and an arbitrary future NOGG_ variable
- **THEN** its fixture processes see only the explicitly supplied fixture context and the test behaves as it does from a clean shell
- **AND** the parent retains its original session identity and environment

#### Scenario: A fixture deliberately tests execution denial

- **WHEN** a fixture supplies an execution role after test environment cleanup
- **THEN** the real guard still refuses protected OpenSpec writes

#### Scenario: Shared cleanup is nested or has no matching variables

- **WHEN** cleanup runs repeatedly or no matching variables are exported
- **THEN** it succeeds under strict shell error handling and preserves unrelated settings

### Requirement: Fixture task ticks never reach the live session broker

Affected direct test entry points and the test runner SHALL discard the caller's
task-broker address before any fixture action. Regression checks SHALL verify
zero contacts with an injected listening sentinel. Tests needing a broker SHALL
use their own isolated fixture endpoint after cleanup.

#### Scenario: A live-looking broker is inherited

- **WHEN** a planning or guard test inherits a listening broker endpoint and runs task-done fixtures
- **THEN** that endpoint receives no connection or request
- **AND** task ticks are confined to the fixture's own state or broker

### Requirement: Planning setup failures are visible and regression tests are portable

Failed planning setup in `nogg.test.sh` SHALL identify the failing scenario and
produce a nonzero result, without silent strict-shell abort or dependent success
assertions. New or changed regressions SHALL run offline on GitHub runners with
no real Beads/Dolt, PID-range assumptions, user-namespace creation or existing
tmux/herdr server. Optional runtime skips SHALL be explicit and SHALL NOT skip
required shell/Python isolation coverage.

#### Scenario: Planning setup fails

- **WHEN** a planning setup command is forced to fail
- **THEN** the test prints a named failure and returns nonzero without reporting its dependent assertions as successful

#### Scenario: A fresh GitHub runner executes the regressions

- **WHEN** no Beads/Dolt service, existing session server or namespace privilege is available
- **THEN** required regressions execute using isolated fixtures, bounded child lifetimes and valid short socket paths

### Requirement: Fixtures that copy the host configuration pin the session backend

A script test that copies the host repository's `.nogging/config.json` into a
scratch repository SHALL pin the scratch repository's session backend to
`tmux` through one shared helper, unless the test exists to exercise another
backend, in which case it SHALL select that backend explicitly and install the
libraries that backend needs. A fixture SHALL NOT inherit the host's
`session_backend` value, and a fixture SHALL NOT copy herdr libraries only to
make an inherited choice load. The helper SHALL change no other key of the
copied configuration.

The repository test runner SHALL pass for a host configuration with
`"session_backend": "herdr"`. A regression check SHALL prove this by running
the affected suites against a scratch checkout whose host config selects herdr,
offline, with no herdr binary, tmux server or live session, and SHALL fail if
a suite that copies the host configuration does not use the helper.

#### Scenario: Host config selects herdr

- **WHEN** the suites that copy the host config run against a host `.nogging/config.json` with `session_backend` `herdr`
- **THEN** they pass exactly as with the key absent
- **AND** each scratch repository's config says `tmux`

#### Scenario: Other keys are preserved

- **WHEN** the helper pins a host config that carries `personas`, `tier_overrides` and custom keys
- **THEN** the pinned copy carries the same values for every key except `session_backend`

#### Scenario: A new suite copies the host config raw

- **WHEN** a script test copies `.nogging/config.json` from the host without the helper and without declaring a backend
- **THEN** the regression check fails and names the suite

#### Scenario: Backend suites keep their own selection

- **WHEN** a suite exists to exercise the herdr backend
- **THEN** it keeps selecting herdr explicitly and is unaffected by the helper
