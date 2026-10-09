## Why

Parallel sessions can exhaust shared account windows mid-task. Launch admission needs current quota evidence, conservative concurrent reservations and visible unknown-data handling before starting another worker.

## What Changes

- Provide nogg usage --agent ... --json and a pre-launch usage gate with exit 75.
- Check every applicable quota bucket and coordinate same-host reservations atomically.
- Add safe opt-in Claude statusline composition and model-aware bounded learned estimates.

## Capabilities

### New Capabilities

- `session-usage`: Quota inspection, admission and estimate history.

### Modified Capabilities

None.

## Impact

Sources: [#53](https://github.com/JoMe92/nogging/issues/53). Estimated execution effort: 4–7 person-days.

Affects the Nogging CLI, managed agent/installer payload, tests and operational documentation as specified in design.md. No execution work, release publication, visibility change or human acceptance sign-off is authorized by this planning artifact.
