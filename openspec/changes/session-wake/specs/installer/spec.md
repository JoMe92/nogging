## ADDED Requirements

### Requirement: The session-wake payload ships with dispatch on

`init` and `update` SHALL ship `scripts/lib/session_signals.py`,
`scripts/lib/session_dispatch.py`, `scripts/lib/session_pause.py`,
`scripts/lib/session_warm.py`, `.pi/extensions/nogging-lifecycle.ts` and
`docs/session-wake.md`, and SHALL scaffold the `session_dispatch` block (with `enabled:
true`, `retire_merged: false`, `wake.keep_warm`, `wake.keep_warm_after` and an empty
`wake.quiet_hours`) and the `orchestrator_context` block. `update` SHALL preserve a
repository's existing values for those keys, `enabled: false` and quiet hours included,
and SHALL NOT write over an existing `enabled`. A repository whose `enabled` key is
missing reads as on, and `update` SHALL print one line saying that dispatch is on, what
it does and that `session_dispatch.enabled: false` switches it off. Neither SHALL edit
`~/.codex`, install a hook into any personal configuration or enable a timer. `remove`
SHALL delete the shipped files and SHALL leave `.nogging/state/dispatch/` and
`.nogging/state/pause.json` in place. Neither `init` nor `update` SHALL create a pause.

#### Scenario: A packed consumer has dispatch on by default

- **WHEN** a packed consumer runs `init`
- **THEN** the files exist, `session_dispatch.enabled` is `true` and `retire_merged` is `false`
- **AND** `session dispatch --once` runs a pass that, with no orchestrator session and no timer, exits 0 and prints no error
- **AND** `doctor` prints notes and no FAIL for the missing orchestrator and timer

#### Scenario: A packed consumer with an orchestrator

- **WHEN** a packed consumer with a stub orchestrator session runs `session dispatch --once` while a Lead idles with uncommitted work
- **THEN** the Lead is nudged once and a queued decision reaches the orchestrator as one digest

#### Scenario: Update keeps an explicit value

- **WHEN** `update` runs in a repository with `session_dispatch.enabled` set to `false`
- **THEN** the value stays `false`, `session dispatch --once` performs no action and no on-by-default line is printed
- **AND** a repository with `enabled` set to `true` keeps `true`

#### Scenario: Update of an older repository turns dispatch on and says so

- **WHEN** `update` runs in a repository whose `session_dispatch` block has no `enabled` key
- **THEN** its existing other values are kept, no `enabled` value is written over the repository's own choice, dispatch reads as on and one line says so and names the switch-off key

#### Scenario: The release says dispatch is on

- **WHEN** the CHANGELOG and `docs/session-wake.md` of the release are read
- **THEN** the CHANGELOG has a line saying that session dispatch is on by default
- **AND** the guide has a section stating plainly that dispatch is on, what it does (fixed nudges, CI tracking, a held digest, no model, no merging, no retirement by default), how to switch it off with `session_dispatch.enabled: false` and how to pause it with `nogg pause`

#### Scenario: Personal configuration is untouched

- **WHEN** `init`, `update` or `remove` runs
- **THEN** `~/.codex/hooks.json` and `~/.codex/config.toml` are unchanged

#### Scenario: A pause survives an update

- **WHEN** `update` runs while `.nogging/state/pause.json` exists
- **THEN** the file is unchanged and the host stays paused
