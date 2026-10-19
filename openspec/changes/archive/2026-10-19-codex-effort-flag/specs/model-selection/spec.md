## MODIFIED Requirements

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
