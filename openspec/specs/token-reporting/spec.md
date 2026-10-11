# token-reporting Specification

## Purpose
Provide operators and the orchestrator with queryable token and duration statistics by time, session, actual model and task complexity.

## Requirements

### Requirement: Flexible filtered reports

`nogg token-usage report` SHALL support arbitrary half-open UTC from/to windows, UTC hourly/daily and per-session grouping, and filters for project, device, runtime, provider, actual model, task, complexity and effort. The default report SHALL cover the current UTC day grouped daily. Session inspection SHALL show lifetime facts for the selected session. Invalid ranges/filters SHALL refuse with a remedy. Token placement SHALL use source completion time; cumulative-only observations SHALL disclose coarse interval attribution rather than invent hourly splits.

#### Scenario: Adjacent windows
- **WHEN** an event completes exactly at 01:00 UTC and reports query [00:00,01:00) and [01:00,02:00)
- **THEN** it contributes only to the second window

#### Scenario: Compare models by task complexity
- **WHEN** an operator filters complexity standard and groups session results for a task across Luna and Opus sessions
- **THEN** actual model-specific consumption, task identity and historical classification remain distinguishable

#### Scenario: Coarse source
- **WHEN** only an aggregate observation interval spanning two hours is available
- **THEN** the report exposes its coarse attribution and does not present invented precise hourly consumption

### Requirement: Honest coverage and stable machine output

Collection, reporting, session inspection and store status SHALL offer versioned JSON suitable for orchestrator use. Reports SHALL show as-of time, coverage/errors, unknown attribution/counters, pending facts and synchronization freshness. Known sums SHALL remain distinguishable from complete totals. Tokens, inference duration and wall runtime SHALL be separate metrics. Usage SHALL not be represented as billed cost or subscription quota percentage.

#### Scenario: Partial source and absent remote
- **WHEN** one adapter is unsupported and no remote is configured
- **THEN** reports include known local facts plus unsupported/local-only status without claiming complete global consumption

#### Scenario: Unknown model and missing cache counter
- **WHEN** a source lacks actual model or cache-write evidence
- **THEN** JSON retains explicit unknown dimensions and missing-counter coverage rather than dropping the session or substituting requested model as observed

### Requirement: Portable fact export

`nogg token-usage export` SHALL emit time-filtered versioned JSONL containing normalized facts and stable identities sufficient for audit and supported recovery without transcript or credential content.

#### Scenario: Export and replay
- **WHEN** a supported export is used to recover a store and the same facts are then collected again
- **THEN** stable identities preserve the original totals without duplicate charging
