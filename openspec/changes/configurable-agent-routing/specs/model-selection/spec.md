## MODIFIED Requirements

### Requirement: Session launch resolves a tier mechanically from the table

`scripts/nogg session launch` SHALL accept `--tier <tier>` for every role. After resolving the agent, it SHALL select each field from the table entry, with the tier's effort taken from a project `tier_overrides` entry for that tier and agent when one exists (see the project-override requirement). When the launch is routed or pinned to an agent routing entry that sets `models` for the tier, the entry's model and effort SHALL take precedence over the table and over `tier_overrides` (see the agent-routing capability). An explicit `--model` SHALL take precedence over the tier model, and an explicit `--effort`, for Claude and Codex, SHALL take precedence over the tier effort, whether that effort comes from a routing entry, a project override or the table. The tier SHALL take precedence over profile values, and profile values over runtime defaults. `--tier`, `--model` and `--effort` SHALL be accepted together. The tier SHALL then still be recorded as `selection_tier`, with its effective tier effort kept as `selection_tier_effort` and the origin of that effort as `selection_tier_effort_source`, for usage attribution, while the explicit model and effort are the requested values with source `launch`. Codex tier effort SHALL reach Codex through the existing reasoning-effort transport without adding a public Codex effort flag. Antigravity tier selection SHALL forward the tier model. Until Claude effort forwarding is available, a Claude tier SHALL apply the model only and SHALL print a notice naming the unapplied effort. Once Claude effort forwarding is available, the Claude tier effort SHALL be forwarded under its capability negotiation. An agent without table entries, such as Pi, SHALL accept `--tier` only on a launch routed or pinned to a routing entry for it, where the tier is recorded with a null `selection_tier_effort` and the model comes from the entry, the profile or the runtime default. An unknown tier, a missing or invalid table, a malformed `tier_overrides` block, or a tier for an agent without table entries and without a routing entry SHALL refuse before any worktree, trust, settings, record or tmux side effect, and the refusal for a table-less agent SHALL name routing as the way to record a tier for it. Launch SHALL NOT probe live model lists and SHALL NOT silently fall back to another model or effort. Without `--tier`, behavior SHALL be unchanged.

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

- **WHEN** `--tier` is unknown, the table is invalid, or the agent is Pi with no routing entry for it
- **THEN** launch refuses with a remedy and creates no worktree, settings, record or tmux session

#### Scenario: A routing entry supplies the tier selection

- **WHEN** a Codex launch routed to an entry whose `models.complex` is `gpt-6-luna` at `medium` passes `--tier complex`, and the project sets `tier_overrides.complex.codex.effort` to `low`
- **THEN** Codex receives model gpt-6-luna and reasoning effort medium
- **AND** the record stores selection_tier complex and selection_tier_effort medium with source route

#### Scenario: Pi records a routed tier

- **WHEN** a launch routed to a Pi entry passes `--tier routine`
- **THEN** Pi starts without a table lookup and the record stores selection_tier routine with a null selection_tier_effort

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

New session records SHALL store `selection_tier`, either the tier or null. Values derived from a tier SHALL use the selection source `launch`, except values supplied by an agent routing entry, which SHALL use the source `route`. New records with a tier SHALL also store `selection_tier_effort_source`, `table`, `project` or `route`, naming where the tier's effort came from; it is null for Antigravity, for an agent without table entries such as Pi, and for records without a tier. `session list` SHALL show `tier=<tier>` for records with a tier, shows an effort that came from a project override as `effort=<level> (project)` and one from a routing entry as `effort=<level> (route)`, and SHALL keep the prior display for records without a tier. Legacy records SHALL remain readable and SHALL NOT be rewritten. An exact-conversation resume SHALL keep its recorded selection and SHALL NOT re-resolve it against a changed table, a changed `tier_overrides` block or a changed routing file, and a record lacking `selection_tier_effort_source` SHALL be read as `table`.

#### Scenario: Tier is visible

- **WHEN** a session launched with `--tier complex` is listed
- **THEN** its row shows `tier=complex` alongside the requested model

#### Scenario: Override attribution is visible

- **WHEN** a Claude session launched with `--tier complex` under a project override of medium is listed
- **THEN** its row shows `effort=medium (project)` and `tier=complex`

#### Scenario: Route attribution is visible

- **WHEN** a Codex session whose `complex` effort came from a routing entry is listed
- **THEN** its row shows `effort=medium (route)` and `tier=complex`

#### Scenario: Resume keeps the recorded override

- **WHEN** a Claude conversation launched with an override of medium is resumed with `--tier complex` after the override was changed to low
- **THEN** the resumed session keeps effort medium and source project and never re-reads the override
