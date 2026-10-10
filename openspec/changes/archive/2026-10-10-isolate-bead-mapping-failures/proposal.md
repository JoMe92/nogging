## Why

An incomplete label pair on one legitimate follow-up currently aborts materialization and mirroring for unrelated changes. Mapping integrity needs explicit scope and an honest representation for non-task follow-ups.

## What Changes

- Recognize openspec:followup with a change label and no task label.
- Quarantine malformed mappings at their affected-change boundary and preserve strict audit diagnostics.
- Report degraded mirror health separately from a clean success.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `beads-sync`: Scoped mapping validation and follow-up semantics.
- `run-recovery`: Visible partial reconciliation health.

## Impact

Sources: [#49](https://github.com/JoMe92/nogging/issues/49). Estimated execution effort: 2–4 person-days.

Affects the Nogging CLI, managed agent/installer payload, tests and operational documentation as specified in design.md. No execution work, release publication, visibility change or human acceptance sign-off is authorized by this planning artifact.
