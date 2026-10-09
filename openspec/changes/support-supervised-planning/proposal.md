## Why

Planning is a first-class persona but the launcher rejects its role, forcing mislabeled Lead sessions and cross-process lock ownership. Orchestration also needs a documented supervised launch permission path.

## What Changes

- Add planning role with optional Bead and explicit planning identifier/description.
- Acquire/release the planning lock within its own session and preserve execution-role boundaries.
- Ship planning prompts and scoped orchestration permissions with actionable diagnostics.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `claude-sessions`: Supervised planning role and role-specific kickoff.
- `session-observability`: Role-specific lead, specialist and planning kickoff without placeholder Beads.
- `workflow-commands`: Canonical planning lifecycle and permissions.
- `tool-agnostic-write-boundary`: Execution sessions remain fenced during concurrent planning.

## Impact

Sources: [#47](https://github.com/JoMe92/nogging/issues/47), [#52](https://github.com/JoMe92/nogging/issues/52). Estimated execution effort: 3–5 person-days.

Affects the Nogging CLI, managed agent/installer payload, tests and operational documentation as specified in design.md. No execution work, release publication, visibility change or human acceptance sign-off is authorized by this planning artifact.
