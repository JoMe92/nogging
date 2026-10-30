## ADDED Requirements

### Requirement: The session-wake payload ships inactive

`init` and `update` SHALL ship `scripts/lib/session_signals.py`,
`scripts/lib/session_dispatch.py`, `.pi/extensions/nogging-lifecycle.ts` and
`docs/session-wake.md`, and SHALL scaffold the `session_dispatch` block with `enabled:
false` and the `orchestrator_context` block. `update` SHALL preserve a repository's
existing values for those keys. Neither SHALL edit `~/.codex`, install a hook into any
personal configuration or enable a timer. `remove` SHALL delete the shipped files and
SHALL leave `.nogging/state/dispatch/` in place.

#### Scenario: A packed consumer is inactive by default

- **WHEN** a packed consumer runs `init`
- **THEN** the files exist, `session_dispatch.enabled` is `false` and `session dispatch --once` performs no action

#### Scenario: Update keeps an enabled dispatcher

- **WHEN** `update` runs in a repository with `session_dispatch.enabled` set to `true`
- **THEN** the value stays `true`

#### Scenario: Personal configuration is untouched

- **WHEN** `init`, `update` or `remove` runs
- **THEN** `~/.codex/hooks.json` and `~/.codex/config.toml` are unchanged
