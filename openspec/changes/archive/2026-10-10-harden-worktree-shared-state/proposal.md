## Why

Worktree-local ignored state causes discovery acknowledgements to disappear and makes the Pi guard treat the OpenSpec boundary as open. Both require an explicit repository-shared state contract.

## What Changes

- Resolve canonical lock and acknowledgement locations from linked worktrees.
- Migrate and merge acknowledgement ledgers atomically.
- Require positive planning authorization and fail closed in the Pi guard.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `beads-sync`: Durable cross-worktree discovery acknowledgements.
- `pi-onboarding`: Canonical locks and positive planning authorization.

## Impact

Sources: [#48](https://github.com/JoMe92/nogging/issues/48), [#55](https://github.com/JoMe92/nogging/issues/55). Estimated execution effort: 1–2 person-days.

Affects the Nogging CLI, managed agent/installer payload, tests and operational documentation as specified in design.md. No execution work, release publication, visibility change or human acceptance sign-off is authorized by this planning artifact.
