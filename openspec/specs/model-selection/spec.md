# model-selection Specification

## Purpose
Map each task complexity tier and agent to a researched model and reasoning effort, so every supervised launch selects them from one validated, versioned rule table instead of ad-hoc choices.

## Requirements

### Requirement: A researched model-selection rule table is shipped and validated

Nogging SHALL ship a versioned rule table and scaffold it as `.nogging/model-selection.json` only when that file is absent. The table SHALL define exactly the tiers `routine`, `standard` and `complex`. For each of `claude`, `codex` and `antigravity` it SHALL give, per tier, a model and, for Claude and Codex, an effort. An Antigravity entry SHALL carry its effort inside the model name and SHALL NOT have an effort key. Validation SHALL reject unknown or missing tiers or agents, efforts outside each agent's supported set, and empty, whitespace-bearing or flag-like model strings. The shipped table SHALL record `table_version` and `researched_at`. The shipped table SHALL agree with the table in `docs/model-selection.md`.

#### Scenario: Shipped table is complete and valid

- **WHEN** `scripts/nogg models check` runs against the shipped table
- **THEN** it succeeds and every tier has an entry for Claude, Codex and Antigravity

#### Scenario: Invalid table is refused

- **WHEN** the table lacks a tier, gives Antigravity an effort key, or gives Codex an unsupported effort
- **THEN** `models check` exits non-zero naming the offending entry

#### Scenario: Consumer edits survive update

- **WHEN** a consumer has edited `.nogging/model-selection.json` and runs update
- **THEN** the file is left byte-for-byte unchanged

### Requirement: Operators can print a table lookup

`scripts/nogg models` SHALL print the full table, or with `--agent` and `--tier` the single resolved entry, in text or `--json`, and SHALL accept `agy` as an alias for `antigravity`. It SHALL perform no live model probe and no write.

#### Scenario: Single lookup

- **WHEN** an operator runs `models --agent codex --tier standard`
- **THEN** the table's Codex standard model and effort are printed

### Requirement: Session launch resolves a tier mechanically from the table

`scripts/nogg session launch` SHALL accept `--tier <tier>` for every role. After resolving the agent, it SHALL select each field from the table entry. An explicit `--model` SHALL take precedence over the tier model, and an explicit `--effort`, for Claude and Codex, SHALL take precedence over the tier effort. The tier SHALL take precedence over profile values, and profile values over runtime defaults. `--tier`, `--model` and `--effort` SHALL be accepted together. The tier SHALL then still be recorded as `selection_tier`, with its table effort kept as `selection_tier_effort`, for usage attribution, while the explicit model and effort are the requested values with source `launch`. Codex tier effort SHALL reach Codex through the existing reasoning-effort transport without adding a public Codex effort flag. Antigravity tier selection SHALL forward the tier model. Until Claude effort forwarding is available, a Claude tier SHALL apply the model only and SHALL print a notice naming the unapplied effort. Once Claude effort forwarding is available, the Claude tier effort SHALL be forwarded under its capability negotiation. An unknown tier, a missing or invalid table, or a tier for an agent without table entries, including Pi, SHALL refuse before any worktree, trust, settings, record or tmux side effect. Launch SHALL NOT probe live model lists and SHALL NOT silently fall back to another model or effort. Without `--tier`, behavior SHALL be unchanged.

#### Scenario: Codex tier selection

- **WHEN** a Codex session launches with `--tier complex`
- **THEN** Codex receives the table's complex model and reasoning effort as separate arguments

#### Scenario: Explicit model wins over tier

- **WHEN** a launch passes `--tier standard` and `--model X`
- **THEN** model X is used while the tier still supplies the effort

#### Scenario: Explicit effort wins over tier

- **WHEN** a Codex launch passes `--tier complex` and `--effort low`
- **THEN** the table's complex model is used with reasoning effort low

#### Scenario: Tier, model and effort together keep the tier recorded

- **WHEN** a Codex launch passes `--tier complex --model gpt-6-luna --effort medium`
- **THEN** Codex receives model gpt-6-luna and reasoning effort medium
- **AND** the record stores selection_tier complex, requested_model gpt-6-luna with source launch and reasoning_effort medium with source launch
- **AND** `session list` shows `tier=complex` alongside the requested model and effort

#### Scenario: Claude before effort forwarding exists

- **WHEN** a Claude session launches with `--tier routine` on a Nogging without Claude effort forwarding
- **THEN** the tier model is applied, no effort flag is emitted, and a notice names the unapplied effort

#### Scenario: Refusals precede side effects

- **WHEN** `--tier` is unknown, the table is invalid, or the agent is Pi
- **THEN** launch refuses with a remedy and creates no worktree, settings, record or tmux session

### Requirement: Tier selection is recorded and listed

New session records SHALL store `selection_tier`, either the tier or null. Values derived from a tier SHALL use the selection source `launch`. `session list` SHALL show `tier=<tier>` for records with a tier and SHALL keep the prior display for records without one. Legacy records SHALL remain readable and SHALL NOT be rewritten. An exact-conversation resume SHALL keep its recorded selection and SHALL NOT re-resolve it against a changed table.

#### Scenario: Tier is visible

- **WHEN** a session launched with `--tier complex` is listed
- **THEN** its row shows `tier=complex` alongside the requested model

### Requirement: Doctor reports table drift without failing

`doctor` SHALL print NOTE lines, never failures, in three cases: a Codex table model is absent from the local Codex model catalog; an Antigravity table model is absent from a bounded `agy models` probe; or the installed table's `table_version` is older than the packaged template's. An unavailable probe source SHALL be reported as unavailable, not as drift. Claude entries SHALL only be format-checked.

#### Scenario: Retired model is noticed

- **WHEN** the table names an Antigravity model that `agy models` no longer lists
- **THEN** doctor prints a NOTE naming that model and its exit status is unchanged
