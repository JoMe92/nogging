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

`scripts/nogg models` SHALL print the full table, or with `--agent` and `--tier` the single resolved entry, in text or `--json`, and SHALL accept `agy` as an alias for `antigravity`. Each Claude or Codex entry SHALL show its effective effort and, when a project `tier_overrides` entry supplied it, mark it `(project)` together with the shipped table effort it replaced; JSON lookups SHALL gain `effort_source` (`table`, `project` or null) and `table_effort` (the shipped table effort or null). The whole-table JSON output SHALL remain the shipped table, unmodified. A malformed `tier_overrides` block SHALL make `models` refuse naming the offending key. It SHALL perform no live model probe and no write.

#### Scenario: Single lookup

- **WHEN** an operator runs `models --agent codex --tier standard`
- **THEN** the table's Codex standard model and effort are printed

#### Scenario: Override is shown with the table value it replaced

- **WHEN** `.nogging/config.json` sets `tier_overrides.complex.codex.effort` to `low` and an operator runs `models --agent codex --tier complex`
- **THEN** the text output shows `effort=low (project; table high)`
- **AND** `--json` gives `effort` low, `effort_source` project and `table_effort` high

#### Scenario: Unoverridden entries are unchanged

- **WHEN** no `tier_overrides` entry exists for an entry
- **THEN** its text output is the prior `model=… effort=…` form and its JSON `effort_source` is `table`

### Requirement: Session launch resolves a tier mechanically from the table

`scripts/nogg session launch` SHALL accept `--tier <tier>` for every role. After resolving the agent, it SHALL select each field from the table entry, with the tier's effort taken from a project `tier_overrides` entry for that tier and agent when one exists (see the project-override requirement). An explicit `--model` SHALL take precedence over the tier model, and an explicit `--effort`, for Claude and Codex, SHALL take precedence over the tier effort, whether that effort comes from a project override or from the table. The tier SHALL take precedence over profile values, and profile values over runtime defaults. `--tier`, `--model` and `--effort` SHALL be accepted together. The tier SHALL then still be recorded as `selection_tier`, with its effective tier effort (override applied) kept as `selection_tier_effort` and the origin of that effort as `selection_tier_effort_source`, for usage attribution, while the explicit model and effort are the requested values with source `launch`. Codex tier effort SHALL reach Codex through the existing reasoning-effort transport without adding a public Codex effort flag. Antigravity tier selection SHALL forward the tier model. Until Claude effort forwarding is available, a Claude tier SHALL apply the model only and SHALL print a notice naming the unapplied effort. Once Claude effort forwarding is available, the Claude tier effort SHALL be forwarded under its capability negotiation. An unknown tier, a missing or invalid table, a malformed `tier_overrides` block, or a tier for an agent without table entries, including Pi, SHALL refuse before any worktree, trust, settings, record or tmux side effect. Launch SHALL NOT probe live model lists and SHALL NOT silently fall back to another model or effort. Without `--tier`, behavior SHALL be unchanged.

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

#### Scenario: Project override supplies the tier effort

- **WHEN** a Codex session launches with `--tier complex` and the project sets `tier_overrides.complex.codex.effort` to `low`
- **THEN** Codex receives the table's complex model and `--reasoning-effort low`
- **AND** the record stores selection_tier complex, selection_tier_effort low and selection_tier_effort_source project

#### Scenario: Explicit effort and model still win over an override

- **WHEN** the same project launches Codex with `--tier complex --model gpt-6-luna --effort medium`
- **THEN** Codex receives model gpt-6-luna and reasoning effort medium
- **AND** the record keeps selection_tier complex and selection_tier_effort low with source project, while reasoning_effort is medium with source launch

#### Scenario: An explicit model alone keeps the override effort

- **WHEN** the same project launches Codex with `--tier complex --model gpt-6-luna` and no `--effort`
- **THEN** Codex receives model gpt-6-luna and reasoning effort low from the override

#### Scenario: Malformed override refuses before side effects

- **WHEN** `tier_overrides` holds an unsupported effort and a launch passes `--tier standard`
- **THEN** launch refuses naming the offending key and the allowed values
- **AND** no worktree, settings, record or tmux session is created
- **AND** a launch without `--tier` is unaffected

### Requirement: Tier selection is recorded and listed

New session records SHALL store `selection_tier`, either the tier or null. Values derived from a tier SHALL use the selection source `launch`. New records with a tier SHALL also store `selection_tier_effort_source`, `table` or `project`, naming where the tier's effort came from; it is null for Antigravity and for records without a tier. `session list` SHALL show `tier=<tier>` for records with a tier, shows an effort that came from a project override as `effort=<level> (project)`, and SHALL keep the prior display for records without a tier. Legacy records SHALL remain readable and SHALL NOT be rewritten. An exact-conversation resume SHALL keep its recorded selection and SHALL NOT re-resolve it against a changed table or a changed `tier_overrides` block, and a record lacking `selection_tier_effort_source` SHALL be read as `table`.

#### Scenario: Tier is visible

- **WHEN** a session launched with `--tier complex` is listed
- **THEN** its row shows `tier=complex` alongside the requested model

#### Scenario: Override attribution is visible

- **WHEN** a Claude session launched with `--tier complex` under a project override of medium is listed
- **THEN** its row shows `effort=medium (project)` and `tier=complex`

#### Scenario: Resume keeps the recorded override

- **WHEN** a Claude conversation launched with an override of medium is resumed with `--tier complex` after the override was changed to low
- **THEN** the resumed session keeps effort medium and source project and never re-reads the override

### Requirement: Doctor reports table drift without failing

`doctor` SHALL print NOTE lines, never failures, in these cases: a Codex table model is absent from the local Codex model catalog; an Antigravity table model is absent from a bounded `agy models` probe; the installed table's `table_version` is older than the packaged template's; the project's `tier_overrides` block is malformed (the NOTE names the first offending key and says tier launches refuse until it is fixed); or a `tier_overrides` effort equals the effort the installed table already gives that entry (the NOTE says the override is redundant and can be removed). Project overrides never change a model, so they SHALL NOT suppress, alter or add the model-drift NOTEs, which are computed from the installed table alone. An unavailable probe source SHALL be reported as unavailable, not as drift. Claude entries SHALL only be format-checked.

#### Scenario: Retired model is noticed

- **WHEN** the table names an Antigravity model that `agy models` no longer lists
- **THEN** doctor prints a NOTE naming that model and its exit status is unchanged

#### Scenario: Overrides do not hide model drift

- **WHEN** a project has a valid `tier_overrides` block and the table also names an Antigravity model that `agy models` no longer lists
- **THEN** doctor prints the same model-drift NOTE as without overrides and its exit status is unchanged

#### Scenario: Malformed override is a NOTE, not a failure

- **WHEN** `tier_overrides` holds an effort outside the agent's supported set
- **THEN** doctor prints a model-selection NOTE naming that key and its exit status is unchanged

#### Scenario: Redundant override is noticed

- **WHEN** an override sets `complex.codex.effort` to the value the installed table already has
- **THEN** doctor prints a NOTE saying the override is redundant

### Requirement: A project can override the tier effort without leaving the tier

A project MAY set `tier_overrides` in `.nogging/config.json`: an object keyed by tier (`routine`, `standard`, `complex`), then by agent (`claude` or `codex`), whose value is an object with exactly one key, `effort`. The effort SHALL be validated against the same set as `--effort` for that agent (Claude `low`, `medium`, `high`, `xhigh`, `max`; Codex `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `ultra`). Unknown tiers, unknown agents (including `antigravity`, whose effort lives in its model name, `pi` and `agy`), unknown keys such as `model`, a non-object block and a non-string effort SHALL be rejected, each naming the offending key. An absent or empty block SHALL mean no overrides, and `nogg update` SHALL leave a consumer's block untouched. The override SHALL replace only the effort of the tier entry it names, after the installed table is read, and SHALL NOT change the model, the tier, the table or `table_version`. The shipped template SHALL include an empty `tier_overrides` block. `scripts/nogg models check` SHALL validate the block, exit non-zero on error and report the number of overrides when valid. Effort precedence for a launch with a tier SHALL be explicit `--effort`, then the project override, then the table effort, then the profile effort, then the runtime default.

#### Scenario: Valid override is accepted

- **WHEN** `tier_overrides` is `{"complex": {"claude": {"effort": "medium"}, "codex": {"effort": "low"}}}`
- **THEN** `models check` succeeds and reports two overrides

#### Scenario: Invalid overrides are refused

- **WHEN** the block names tier `urgent`, agent `antigravity`, key `model`, or Codex effort `turbo`
- **THEN** `models check` exits non-zero naming that key

#### Scenario: Override never changes the model or the table

- **WHEN** an override is set and an operator lists `models --agent codex --tier complex`
- **THEN** the model is the table's model and `.nogging/model-selection.json` is byte-for-byte unchanged

#### Scenario: Update keeps the block

- **WHEN** a consumer has a `tier_overrides` block and runs `nogg update`
- **THEN** `.nogging/config.json` still carries the block unchanged
