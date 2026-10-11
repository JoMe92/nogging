## Why

Operators need another supervised runtime and quota pool without leaving Nogging ownership, guards or observability. The downstream prototype reduces discovery work but still lacks upstream packaging and full lifecycle acceptance.

## What Changes

- Add antigravity agent selection with agy alias, profiles, exact-conversation resume and model forwarding.
- Install a fail-closed guard, preserve hook settings and safely prepare workspace trust.
- Integrate pane/events/quota adapters, workflow skills, lifecycle docs and live acceptance.

## Capabilities

### New Capabilities

- `antigravity-onboarding`: Runtime-specific guard, trust, configuration and installation.

### Modified Capabilities

- `session-usage`: Antigravity usage source and model-group buckets. (created by gate-session-usage; prerequisite of AGR-005 quota integration only).
- `agent-neutral-launch`: Fourth supported agent selection.

## Impact

Sources: [#54](https://github.com/JoMe92/nogging/issues/54). Estimated execution effort: 5–10 person-days with reusable prototype.

Affects the Nogging CLI, managed agent/installer payload, tests and operational documentation as specified in design.md. No execution work, release publication, visibility change or human acceptance sign-off is authorized by this planning artifact.
