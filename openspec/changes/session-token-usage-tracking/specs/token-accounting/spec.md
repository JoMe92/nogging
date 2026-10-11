## Purpose

Persist attributable token consumption and runtime from supervised agents so operators can compare actual models and task complexity across sessions.

## ADDED Requirements

### Requirement: Normalize authoritative runtime usage

The system SHALL collect source-reported usage for supervised Claude, Codex and Antigravity sessions, including bead-less planning/orchestrator sessions and exact-conversation resumes. It SHALL expose inclusive input, output, cache read/write, thinking and provider totals with source/version/semantics evidence. Cached tokens and thinking subsets MUST NOT be added twice. Unsupported counters SHALL remain unknown rather than zero. Pi support is deferred.

#### Scenario: Overlapping Codex streams
- **WHEN** a rollout contains per-response usage plus turn/thread summaries and token-count events for the same work
- **THEN** consumption is charged once using the supported authoritative stream and exact source identities

#### Scenario: Claude repeated streaming records
- **WHEN** multiple assistant blocks repeat or revise usage for the same request/message
- **THEN** one effective supported snapshot contributes, cache TTL/iteration breakdowns are not added again, and an incompatible revision is diagnosed

#### Scenario: Antigravity command versus inference usage
- **WHEN** `/usage` returns zero command usage or account quota data without evidence for the target conversation
- **THEN** the collector does not treat it as complete conversation accounting
- **AND** supported collection requires exact-conversation usage/model evidence, verified with nonzero supervised inference

#### Scenario: Missing or inconsistent numeric data
- **WHEN** a source omits cache-write counters or reports incompatible totals
- **THEN** the missing field is unknown and inconsistency appears in coverage diagnostics without fabricated totals

### Requirement: Preserve historical task and selection attribution

Each usage event SHALL retain project/session/runtime identity, applicable task/Bead/change or planning identity, role, actual provider/model, requested selection and effort provenance. Complexity SHALL be `routine`, `standard`, `complex` or `unknown`, with classification source and vocabulary/selection version where available. The system MUST NOT infer complexity from model or rewrite history from current task labels. Optional model-selection metadata SHALL use `selection_tier`; explicit launch complexity SHALL work independently of automatic selection.

#### Scenario: Optional tier and explicit complexity
- **WHEN** a launch has `selection_tier=complex` and explicit complexity `routine`
- **THEN** it refuses the disagreement before launch side effects

#### Scenario: Legacy session and changed table
- **WHEN** a legacy session lacks classification or today's model table differs from its launch table
- **THEN** missing complexity remains unknown and recorded historical selection remains intact

#### Scenario: Task or model transition
- **WHEN** a supervised session changes task or its observed model changes
- **THEN** new usage receives the known applicable attribution boundary and model, without guessing ownership for ambiguous intervals

#### Scenario: Resumes and child sessions
- **WHEN** a conversation resumes or child usage is separately available
- **THEN** prior usage is not charged again and each source event contributes once, with parent/child relationships preserved where proven

### Requirement: Automatic durable supervised collection

Collection SHALL be driven by host supervision and bounded refresh/recovery, with a final flush on terminal transitions and before cleanup. It SHALL not rely on agents remembering to report or require broader restricted-agent authority. A local failure SHALL preserve pending allowlisted facts and attribution durably, show degraded coverage, and allow the underlying user task to continue. Checkpoints SHALL advance only after durable ingestion, with idempotent replay and partial-line/rotation handling. Prompts, tool text and credentials MUST NOT enter the usage store or exports.

#### Scenario: Store failure and recovery
- **WHEN** Dolt becomes unavailable during collection
- **THEN** pending normalized facts are retained, status reports the failure, and later recovery imports them exactly once

#### Scenario: Crash around checkpoint update
- **WHEN** collection crashes after storing facts but before advancing the source cursor
- **THEN** replay produces the same counts without duplicate rows or lost events

#### Scenario: Cleanup with pending evidence
- **WHEN** cleanup would delete the only unpersisted attribution or source evidence
- **THEN** it preserves that evidence or refuses cleanup with an actionable remedy

#### Scenario: Restricted session
- **WHEN** a restricted agent runs
- **THEN** the host collects validated facts without granting the agent database credentials, remote access or arbitrary file authority

### Requirement: Runtime duration is separate from inference time

The system SHALL report supervised process runtime as observed segments including idle time and excluding restart downtime, with provisional live values and explicit partial evidence for unknown crash exits. Provider inference duration SHALL be separate. Window reports SHALL clip segment overlap without repeating whole-session runtime for every model row.

#### Scenario: Restart gap and model split
- **WHEN** a session runs ten minutes, stops twenty minutes, then runs five minutes across two models
- **THEN** its complete wall runtime is fifteen minutes, and model grouping does not multiply it

#### Scenario: Unobserved crash
- **WHEN** exit time cannot be established
- **THEN** duration is marked partial with the observed bound, rather than extended until the next collection
