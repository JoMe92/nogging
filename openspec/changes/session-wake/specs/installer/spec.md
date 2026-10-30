## ADDED Requirements

### Requirement: The session-wake payload ships inactive

`init` and `update` SHALL ship `scripts/lib/session_signals.py`,
`scripts/lib/session_dispatch.py`, `scripts/lib/session_pause.py`,
`scripts/lib/session_warm.py`, `.pi/extensions/nogging-lifecycle.ts` and
`docs/session-wake.md`, and SHALL scaffold the `session_dispatch` block (with `enabled:
false`, `wake.keep_warm`, `wake.keep_warm_after` and an empty `wake.quiet_hours`) and the
`orchestrator_context` block. `update` SHALL preserve a repository's existing values for
those keys, quiet hours included. Neither SHALL edit `~/.codex`, install a hook into any
personal configuration or enable a timer. `remove` SHALL delete the shipped files and
SHALL leave `.nogging/state/dispatch/` and `.nogging/state/pause.json` in place. Neither
`init` nor `update` SHALL create a pause.

#### Scenario: A packed consumer is inactive by default

- **WHEN** a packed consumer runs `init`
- **THEN** the files exist, `session_dispatch.enabled` is `false` and `session dispatch --once` performs no action

#### Scenario: Update keeps an enabled dispatcher

- **WHEN** `update` runs in a repository with `session_dispatch.enabled` set to `true`
- **THEN** the value stays `true`

#### Scenario: Personal configuration is untouched

- **WHEN** `init`, `update` or `remove` runs
- **THEN** `~/.codex/hooks.json` and `~/.codex/config.toml` are unchanged

#### Scenario: A pause survives an update

- **WHEN** `update` runs while `.nogging/state/pause.json` exists
- **THEN** the file is unchanged and the host stays paused
