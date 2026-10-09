## Context

See proposal.md for the issue scope. Baseline is origin/develop fetched on 2026-10-09. Existing implementation and closed Beads are retained; each task verifies its delta and records evidence.

## Goals / Non-Goals

**Goals:** Deliver every normative scenario in the capability deltas with an installed-consumer regression check and explicit failure behavior.

**Non-Goals:** Reimplement closed Beads, rewrite Git/Dolt history, publish a release, change repository visibility, or sign human acceptance.

## Decisions

1. Define canonical mapped work as exactly one change label and one task label. Define non-task follow-up as openspec:followup plus exactly one change label and no task label; plain unmapped Beads remain valid. A follow-up with a task label is an error, not a substitute mapping.

2. Keep validate/audit strict and nonzero on malformed mappings; materialize(target) gates only target-affecting defects, while sync computes independent per-change plans. Skip/quarantine the entire affected change so no partial checkbox/log evidence misrepresents its completeness.

3. Duplicate task IDs, duplicate mapped Beads and missing/mismatched task references quarantine every identifiable affected change. Truly ambiguous identities, unreadable tracker state and duplicate global spec task definitions fail closed repository-wide. Never silently delete labels or Beads.

4. Follow-ups do not satisfy tasks.md mappings and are not mirrored to a fabricated checkbox. Blocking follow-ups must have explicit Beads dependency edges; completion logic uses approved mapped tasks and unresolved blocking dependencies, not every conceptually associated Bead.

5. Persist last complete success separately from last partial pass, recording skipped IDs/changes/reasons. Partial pass returns a documented nonzero degraded exit, without retrying unrelated successful writes or losing idempotency. Doctor reports exact scope and age; repair clears only resolved diagnostics.

6. Includes the duplicate-label discovery SPEC-i343. Existing malformed labels stay visible until explicitly repaired by planning; no automatic relabeling migration.

## Dependencies and execution order

Entry task requires TASK-WSS-005. Tasks inside this change form an explicit linear Beads dependency chain; no reliance on tasks.md ordering alone. Cross-change edges are materialized after the planning commit and before execution. This conservative integration order prevents simultaneous edits to scripts/nogg and wrapper contracts.

## Risks / Trade-offs

- Runtime behavior and CLI schemas can change → first validate installed versions and sanitized fixtures; unknown unsupported behavior fails explicitly and becomes a discovery.
- Shared CLI edits can conflict → complete and integrate the prerequisite change into develop before allocating the dependent implementation worktree; a closed task alone does not prove integration.
- Automated mocks can miss interactive failures → final task includes the specified live checks and unsigned evidence; blocked acceptance remains recorded rather than presented as pass.

## Migration Plan

Install through the normal pinned init/update path; preserve consumer-owned state and unrelated configuration. Validate upgrade fixtures before rollout. Roll back tool payload to the previous pinned release without deleting new user-owned state; retain backups required by the scoped migration. Runtime/profile defaults remain unchanged except where the requirements explicitly specify a correction.
