## Context

See proposal.md for the issue scope. Baseline is origin/develop fetched on 2026-10-09. Existing implementation and closed Beads are retained; each task verifies its delta and records evidence.

## Goals / Non-Goals

**Goals:** Deliver every normative scenario in the capability deltas with an installed-consumer regression check and explicit failure behavior.

**Non-Goals:** Reimplement closed Beads, rewrite Git/Dolt history, publish a release, change repository visibility, or sign human acceptance.

## Decisions

1. Resolve the common Git directory with git rev-parse --path-format=absolute --git-common-dir and the main checkout through worktree metadata; support relative git-common-dir, spaces and .git indirection. Do not assume every common dir is a literal .git directory; unsupported layouts fail explicitly.

2. Use the main checkout .nogging/state and .nogging/locks as the canonical existing location, with a shared resolver. Keep worktree-specific session work directories distinct. Do not relocate all Nogging state speculatively.

3. Merge legacy acknowledgement IDs from the invoking checkout into canonical state under a short write lock, use temporary-file plus atomic replacement, preserve timestamps conservatively and keep a recovery backup. Never infer acknowledgement from status.

4. Pi must consult canonical locks at call time; no sentinel is not proof of planning. A fresh valid lock plus no closed sentinel authorizes only a planning role. Main-worker/execution roles remain read-only; expose role context through the supervised wrapper with a conservative standalone default.

5. Keep Pi floor-only authority documented; do not silently add a new restricted permission split while fixing #55. Reuse tested lock-resolution behavior for the later Antigravity guard.

## Dependencies and execution order

Entry task requires TASK-PSC-006. Tasks inside this change form an explicit linear Beads dependency chain; no reliance on tasks.md ordering alone. Cross-change edges are materialized after the planning commit and before execution. This conservative integration order prevents simultaneous edits to scripts/nogg and wrapper contracts.

## Risks / Trade-offs

- Runtime behavior and CLI schemas can change → first validate installed versions and sanitized fixtures; unknown unsupported behavior fails explicitly and becomes a discovery.
- Shared CLI edits can conflict → complete and integrate the prerequisite change into develop before allocating the dependent implementation worktree; a closed task alone does not prove integration.
- Automated mocks can miss interactive failures → final task includes the specified live checks and unsigned evidence; blocked acceptance remains recorded rather than presented as pass.

## Migration Plan

Install through the normal pinned init/update path; preserve consumer-owned state and unrelated configuration. Validate upgrade fixtures before rollout. Roll back tool payload to the previous pinned release without deleting new user-owned state; retain backups required by the scoped migration. Runtime/profile defaults remain unchanged except where the requirements explicitly specify a correction.
