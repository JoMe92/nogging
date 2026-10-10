## Why

Installed repositories can lack the launch wrapper and log writer, so every supervised agent may fail before its first turn. Updates also need to detect mismatched CLI contracts before destroying the diagnostic pane.

## What Changes

- Ship and refresh executable session-launch and session-log-writer on init/update; remove only owned payload on uninstall.
- Preflight wrapper compatibility and preserve startup errors in a durable log before tmux can discard a failed pane.
- Exercise consumer installation, upgrades and optional config defaults using self-contained test fixtures.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `installer`: Complete supervised-session payload and consumer lifecycle.
- `claude-sessions`: Preflight and diagnostic behavior for every supported agent.

## Impact

Sources: [#43](https://github.com/JoMe92/nogging/issues/43), [#51](https://github.com/JoMe92/nogging/issues/51). Estimated execution effort: 1–2 person-days.

Affects the Nogging CLI, managed agent/installer payload, tests and operational documentation as specified in design.md. No execution work, release publication, visibility change or human acceptance sign-off is authorized by this planning artifact.
