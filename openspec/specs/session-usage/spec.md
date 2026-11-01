# session-usage Specification

## Purpose
Quota inspection, admission and estimate history. This capability defines reliable observable behavior for Nogging operators and supervised sessions.

## Requirements

### Requirement: Quota inspection reports every applicable usage window

Nogging usage SHALL report used percent, reset/observation times, running reservations, estimate, projection and fit for every applicable short and weekly bucket of the selected provider/model group. Missing, malformed, unsupported or stale sources SHALL be explicitly unknown and SHALL never be treated as zero usage. A Codex observation is the host's newest rollout quota sample and SHALL remain valid for each window until that window's own reset time, even when older than the configured staleness; it SHALL be marked stale rather than discarded. The configured staleness continues to expire Claude and Antigravity observations.

#### Scenario: Weekly exhausted but short window available

- **WHEN** the weekly bucket exceeds the cap while the short window fits
- **THEN** usage reports the weekly bucket as limiting

#### Scenario: Stale source

- **WHEN** Claude or Antigravity usage data is older than configured staleness
- **THEN** usage reports unknown with its reason

#### Scenario: Aged Codex observation before reset

- **WHEN** the newest Codex observation is older than the configured staleness but its windows' reset times are in the future
- **THEN** usage reports those windows as known, marked stale, with their observed percent
- **AND** a weekly window over the cap makes admission denied naming the weekly reset, never unknown-admitted

#### Scenario: Codex window reset elapsed

- **WHEN** a Codex window's reset time has passed
- **THEN** that window is unknown with a fresh-observation-required reason, while a still-valid window remains known

### Requirement: Execution launch admission is atomic and precedes launch side effects

With the usage gate enabled, an execution launch SHALL reserve estimated headroom atomically against every applicable same-host account bucket before launch side effects. Default cap SHALL be 92 percent and default estimate 5 percent. Denial SHALL exit 75 naming limiting reset times. Unknown data SHALL warn and proceed by default or deny when configured; explicit --ignore-usage-gate SHALL be recorded. When unknown data is admitted, the launch SHALL print a prominent WARN naming the agent, each unknown window's reason and remediation hint, and the `usage_gate.on_unknown` setting that blocks, and `doctor` SHALL print a NOTE while an agent's usage is unknown under the warn policy. The default policy SHALL NOT change to deny. Planning and orchestrator launches SHALL be excluded by default.

#### Scenario: Concurrent final slot

- **WHEN** two local launches race for headroom fitting only one reservation
- **THEN** only one is admitted and the other exits 75 without creating a session

#### Scenario: Launch failure

- **WHEN** an admitted launch fails before becoming live
- **THEN** its reservation is released

#### Scenario: Unknown default

- **WHEN** no fresh supported usage source exists and unknown policy is warn
- **THEN** launch prints a WARN naming the unknown reasons and how to block, and continues without claiming the usage is known

#### Scenario: Doctor flags admitted-unknown agents

- **WHEN** an agent's usage is unknown and `usage_gate.on_unknown` is warn
- **THEN** `doctor` prints a NOTE saying launches are admitted without known headroom and how to block them
- **AND** the NOTE is absent when usage is known, the policy is deny, or the gate is disabled

### Requirement: Usage collection preserves settings and honest cost attribution

Installing Claude usage capture SHALL be explicit and preserve unrelated settings and existing statusline behavior. Learned estimates SHALL exclude resets and unassignable concurrent account deltas, use a bounded history and fall back conservatively when insufficient. Resume scheduling SHALL honor limiting reset times without model switching as a limit workaround.

#### Scenario: Existing statusline

- **WHEN** usage capture is installed where a user statusline already exists
- **THEN** its behavior is preserved through explicit composition or installation refuses with manual instructions

#### Scenario: Overlapping workers

- **WHEN** an account delta spans concurrent sessions
- **THEN** it is not recorded as an attributable per-model sample

### Requirement: Antigravity quota uses the selected model group and each limiting bucket

The Antigravity usage adapter SHALL normalize the runtime read-only /usage result, select the chosen model group and evaluate weekly and short buckets independently. Unknown model/group mapping SHALL be unknown usage; an unset model SHALL report that no model was selected and that `--model` is required, distinct from an unrecognised model. Every Antigravity model named in the model-selection table SHALL map to exactly one runtime group. Resume timing SHALL honor all exhausted applicable buckets; a headless response with denied_actions or error status SHALL not be accepted as success solely because exit status is zero.

#### Scenario: Independent quota pools

- **WHEN** the selected model belongs to a different group than another running model
- **THEN** admission uses the selected group buckets only

#### Scenario: Weekly bucket blocks resume

- **WHEN** weekly quota remains exhausted after short-window reset
- **THEN** resume waits for the limiting weekly reset rather than resuming immediately

#### Scenario: Table models map

- **WHEN** usage is inspected for any Antigravity model in the model-selection table
- **THEN** it resolves to the one group listing that model's family and reports both buckets

#### Scenario: No model selected

- **WHEN** Antigravity usage is inspected without a model
- **THEN** the windows are unknown with a reason stating no model was selected and to pass `--model`

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

### Requirement: Missing usage sources name their remediation

When a usage window is unknown because an opt-in source is absent, the report SHALL carry an advisory hint naming the remedy, without changing any admission decision. For Claude without the statusline capture the hint SHALL be one line that names `nogg usage install-statusline`, states its effect (a capture wrapper installed as the `statusLine` in the Claude settings, previewable with `--dry-run`) and links the documentation section on why Claude usage is unknown by default. It SHALL be shown by `nogg usage`, the unknown-admitted launch warning and `doctor`.

#### Scenario: Claude statusline not installed

- **WHEN** `nogg usage --agent claude` runs with no statusline capture cache
- **THEN** each window is unknown (missing usage source) and the output names `nogg usage install-statusline`, states that it installs a capture wrapper as the Claude `statusLine`, and links the documentation section
- **AND** the gate decision is unchanged

#### Scenario: Hint reaches doctor

- **WHEN** `doctor` runs with no Claude capture cache
- **THEN** its quota NOTE names `nogg usage install-statusline`, states its effect and links the documentation section

### Requirement: Claude usage capture is previewable and reversible

`nogg usage install-statusline --dry-run` SHALL print the intended change to the Claude settings file (the wrapper path, any composed existing command and a diff of the settings text) and SHALL write nothing, including no wrapper, settings, backup or directory. A real install that changes the settings SHALL first back up the existing settings file and SHALL record the previous `statusLine` value, or its absence. `nogg usage uninstall-statusline` SHALL restore only the `statusLine` key from that record (removing the key when there was none), preserve every other setting, back up the settings file before changing it, and remove the wrapper and the record. It SHALL be a no-op reporting `not_installed` when the capture is not installed, SHALL refuse without changes on a malformed settings file or when no previous value can be determined, and SHALL accept `--dry-run` and `--json`.

#### Scenario: Dry run changes nothing

- **WHEN** `nogg usage install-statusline --dry-run` runs against scratch settings with an existing statusline
- **THEN** it prints the wrapper path, the composed command and a settings diff
- **AND** the settings file, the wrapper location and every directory are byte-for-byte unchanged

#### Scenario: Install then uninstall restores the previous statusLine

- **WHEN** capture is installed over a `statusLine` object with extra keys and an unrelated setting is edited afterwards, then `nogg usage uninstall-statusline` runs
- **THEN** the original `statusLine` object is back exactly and the edited unrelated setting is preserved
- **AND** the install and uninstall backups exist and the wrapper and restore record are gone

#### Scenario: No prior statusline

- **WHEN** capture was installed with no previous `statusLine` and is then uninstalled
- **THEN** the `statusLine` key is removed and all other settings are unchanged

#### Scenario: Not installed

- **WHEN** `nogg usage uninstall-statusline` runs and the statusline does not reference the wrapper, or runs a second time
- **THEN** it reports `not_installed`, exits 0 and changes nothing

#### Scenario: Install made before the restore record existed

- **WHEN** uninstall runs for a capture installed without a restore record and the wrapper still names its composed command
- **THEN** the composed command is restored as a command statusline, or the key is removed when none was composed
