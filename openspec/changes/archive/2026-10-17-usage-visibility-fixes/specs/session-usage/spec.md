## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: Missing usage sources name their remediation

When a usage window is unknown because an opt-in source is absent, the report SHALL carry an advisory hint naming the remedy, without changing any admission decision. For Claude without the statusline capture the hint SHALL be `run nogg usage install-statusline`, shown by `nogg usage`, the unknown-admitted launch warning and `doctor`.

#### Scenario: Claude statusline not installed

- **WHEN** `nogg usage --agent claude` runs with no statusline capture cache
- **THEN** each window is unknown (missing usage source) and the output names `nogg usage install-statusline`
- **AND** the gate decision is unchanged

#### Scenario: Hint reaches doctor

- **WHEN** `doctor` runs with no Claude capture cache
- **THEN** its quota NOTE names `nogg usage install-statusline`
