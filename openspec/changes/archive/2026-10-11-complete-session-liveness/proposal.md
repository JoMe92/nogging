## Why

Core fixes for #37–#40 and part of #41/#42 are already merged, but original acceptance, CI observation and placeholder semantics remain incomplete. Existing discovery evidence also shows stale hook states and ambient-environment test failures.

## What Changes

- Validate existing dependency/profile/kickoff behavior rather than implement it twice.
- Correct completion/blocking scope, expose unchecked PR checks and reconcile stale hook events.
- Distinguish suggestions from actual input and require deliberate messages for nudges.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `session-observability`: Trustworthy sweep, input handling and event freshness.

## Impact

Sources: [#37](https://github.com/JoMe92/nogging/issues/37), [#38](https://github.com/JoMe92/nogging/issues/38), [#39](https://github.com/JoMe92/nogging/issues/39), [#40](https://github.com/JoMe92/nogging/issues/40), [#41](https://github.com/JoMe92/nogging/issues/41), [#42](https://github.com/JoMe92/nogging/issues/42). Estimated execution effort: 2–4 person-days.

Affects the Nogging CLI, managed agent/installer payload, tests and operational documentation as specified in design.md. No execution work, release publication, visibility change or human acceptance sign-off is authorized by this planning artifact.
