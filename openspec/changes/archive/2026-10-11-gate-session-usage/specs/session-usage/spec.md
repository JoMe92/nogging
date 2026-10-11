## Purpose

Quota inspection, admission and estimate history. This capability defines reliable observable behavior for Nogging operators and supervised sessions.

## ADDED Requirements

### Requirement: Quota inspection reports every applicable usage window

Nogging usage SHALL report used percent, reset/observation times, running reservations, estimate, projection and fit for every applicable short and weekly bucket of the selected provider/model group. Missing, malformed, unsupported or stale sources SHALL be explicitly unknown and SHALL never be treated as zero usage.

#### Scenario: Weekly exhausted but short window available

- **WHEN** the weekly bucket exceeds the cap while the short window fits
- **THEN** usage reports the weekly bucket as limiting

#### Scenario: Stale source

- **WHEN** usage data is older than configured staleness
- **THEN** usage reports unknown with its reason

### Requirement: Execution launch admission is atomic and precedes launch side effects

With the usage gate enabled, an execution launch SHALL reserve estimated headroom atomically against every applicable same-host account bucket before launch side effects. Default cap SHALL be 92 percent and default estimate 5 percent. Denial SHALL exit 75 naming limiting reset times. Unknown data SHALL warn and proceed by default or deny when configured; explicit --ignore-usage-gate SHALL be recorded. Planning and orchestrator launches SHALL be excluded by default.

#### Scenario: Concurrent final slot

- **WHEN** two local launches race for headroom fitting only one reservation
- **THEN** only one is admitted and the other exits 75 without creating a session

#### Scenario: Launch failure

- **WHEN** an admitted launch fails before becoming live
- **THEN** its reservation is released

#### Scenario: Unknown default

- **WHEN** no fresh supported usage source exists and unknown policy is warn
- **THEN** launch warns and continues without claiming the usage is known

### Requirement: Usage collection preserves settings and honest cost attribution

Installing Claude usage capture SHALL be explicit and preserve unrelated settings and existing statusline behavior. Learned estimates SHALL exclude resets and unassignable concurrent account deltas, use a bounded history and fall back conservatively when insufficient. Resume scheduling SHALL honor limiting reset times without model switching as a limit workaround.

#### Scenario: Existing statusline

- **WHEN** usage capture is installed where a user statusline already exists
- **THEN** its behavior is preserved through explicit composition or installation refuses with manual instructions

#### Scenario: Overlapping workers

- **WHEN** an account delta spans concurrent sessions
- **THEN** it is not recorded as an attributable per-model sample
