# session-usage Specification

## Purpose
Quota inspection, admission and estimate history. This capability defines reliable observable behavior for Nogging operators and supervised sessions.

## Requirements

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

### Requirement: Antigravity quota uses the selected model group and each limiting bucket

The Antigravity usage adapter SHALL normalize the runtime read-only /usage result, select the chosen model group and evaluate weekly and short buckets independently. Unknown model/group mapping SHALL be unknown usage. Resume timing SHALL honor all exhausted applicable buckets; a headless response with denied_actions or error status SHALL not be accepted as success solely because exit status is zero.

#### Scenario: Independent quota pools

- **WHEN** the selected model belongs to a different group than another running model
- **THEN** admission uses the selected group buckets only

#### Scenario: Weekly bucket blocks resume

- **WHEN** weekly quota remains exhausted after short-window reset
- **THEN** resume waits for the limiting weekly reset rather than resuming immediately

### Requirement: Reservation entries have a stable versioned accounting contract

Nogging SHALL keep one same-user host-wide reservation ledger across repositories
and releases. New entries SHALL declare integer schema version 1 without changing
the token-map container or common lock. Readers SHALL accept both existing
unversioned formats and version 1. Scope, finite nonnegative estimate, owner
identity and reset-window accounting SHALL remain interpretable across versions.

#### Scenario: Legacy and versioned entries share headroom

- **WHEN** the shared ledger contains unversioned tmux, unversioned backend-neutral and version-1 reservations
- **THEN** usage and admission count every matching live reservation under the same scope and reset-window rules
- **AND** concurrent launches cannot reserve the same final slot

#### Scenario: New reservation is bound

- **WHEN** a new pending reservation is created and then bound to a session
- **THEN** its entry declares version 1 throughout and retains its accounting identity and unknown extensions

### Requirement: Ununderstood reservations cannot silently release headroom

Readers SHALL retain and count unsupported versions or malformed session metadata
when the stable accounting core is valid. They SHALL report the compatibility
problem, preserve the complete opaque entry across unrelated writes, and SHALL
NOT probe, inspect terminal session state, reap or mutate that entry. An explicit
mutation targeting an opaque entry SHALL refuse with a diagnostic. Invalid ledger
containers or unusable accounting SHALL produce a controlled failure before
launch side effects, without modifying the ledger or treating reservations as zero.
Read-only inspection SHALL NOT write or create ledger state.

#### Scenario: Future entry remains reserved

- **WHEN** a reader encounters a higher-version reservation with valid accounting and a terminal-looking session record
- **THEN** it counts the reservation for matching scope/windows without invoking its probe or inspecting that record
- **AND** an unrelated admission, bind or release preserves the opaque entry including unknown fields

#### Scenario: Malformed session with usable accounting

- **WHEN** an entry has invalid session metadata or an invalid explicit version but a valid accounting core
- **THEN** the reader reports the incompatibility and conservatively retains and counts it without an uncaught shape exception

#### Scenario: Opaque mutation is refused

- **WHEN** a bind or release explicitly targets an opaque reservation
- **THEN** the operation fails with a diagnostic and leaves that entry unchanged

#### Scenario: Unusable accounting fails safely

- **WHEN** any entry has an uninterpretable estimate, scope, owner or reset-window mapping
- **THEN** inspection or admission reports a controlled ledger error without a traceback or launch side effects
- **AND** the ledger remains unchanged even when unknown-quota policy is warn

#### Scenario: Inspection preserves storage

- **WHEN** usage inspects a mixed-version ledger or an absent ledger
- **THEN** existing ledger bytes remain unchanged and absent ledger state is not created

### Requirement: Mixed-release support declares its compatibility floor honestly

Operator guidance SHALL distinguish tolerant patched readers from unpatched
v2.2.0. It SHALL require updating older consumers before relying on mixed-release
operation, and SHALL NOT claim that a version marker repairs already released
readers. Recovery guidance SHALL preserve live reservations and shared accounting.

#### Scenario: An operator runs an unpatched consumer beside develop

- **WHEN** the operator consults the mixed-release recovery guidance
- **THEN** it explains the update requirement and the known unsupported old reader
- **AND** it does not prescribe deleting live reservations or splitting the ledger
