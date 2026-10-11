## Context

See proposal.md for the issue scope. Baseline is origin/develop fetched on 2026-10-09. Existing implementation and closed Beads are retained; each task verifies its delta and records evidence.

## Goals / Non-Goals

**Goals:** Deliver every normative scenario in the capability deltas with an installed-consumer regression check and explicit failure behavior.

**Non-Goals:** Reimplement closed Beads, rewrite Git/Dolt history, publish a release, change repository visibility, or sign human acceptance.

## Decisions

1. Precedence is explicit --model, then profile model, then native runtime default. Record requested_model and model_source; unknown runtime default displays runtime-default, never an invented effective model. Reasoning effort is Codex-only and optional.

2. Forward argv as separate elements with native CLI validation for model names; no shell interpolation. Reject unsupported reasoning-effort values and cross-agent profile suffixes before side effects. Do not maintain a fast-staling list of model names.

3. Read installed Codex help/local official documentation for flags during execution, and verify the existing shared Git/.beads access limitation in a real worktree. Do not solve it by disabling sandbox/execpolicy. If the currently supported authority cannot perform the lifecycle, record a blocking discovery with a reproducible remedy rather than advertising unsupported unattended operation.

4. Keep legacy profiles valid, Pi existing selection unchanged, and add the chosen model to durable session metadata/list so usage-gate adapters can key estimates on it.

## Dependencies and execution order

Entry task requires TASK-SSP-006. Tasks inside this change form an explicit linear Beads dependency chain; no reliance on tasks.md ordering alone. Cross-change edges are materialized after the planning commit and before execution. This conservative integration order prevents simultaneous edits to scripts/nogg and wrapper contracts.

## Risks / Trade-offs

- Runtime behavior and CLI schemas can change → first validate installed versions and sanitized fixtures; unknown unsupported behavior fails explicitly and becomes a discovery.
- Shared CLI edits can conflict → complete and integrate the prerequisite change into develop before allocating the dependent implementation worktree; a closed task alone does not prove integration.
- Automated mocks can miss interactive failures → final task includes the specified live checks and unsigned evidence; blocked acceptance remains recorded rather than presented as pass.

## Migration Plan

Install through the normal pinned init/update path; preserve consumer-owned state and unrelated configuration. Validate upgrade fixtures before rollout. Roll back tool payload to the previous pinned release without deleting new user-owned state; retain backups required by the scoped migration. Runtime/profile defaults remain unchanged except where the requirements explicitly specify a correction.
