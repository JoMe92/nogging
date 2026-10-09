## Context

See proposal.md for the issue scope. Baseline is origin/develop fetched on 2026-10-09. Existing implementation and closed Beads are retained; each task verifies its delta and records evidence.

## Goals / Non-Goals

**Goals:** Deliver every normative scenario in the capability deltas with an installed-consumer regression check and explicit failure behavior.

**Non-Goals:** Reimplement closed Beads, rewrite Git/Dolt history, publish a release, change repository visibility, or sign human acceptance.

## Decisions

1. Normalize observations as provider/account/model-group, bucket/window, used percent, reset UTC and observed UTC; check both short and weekly windows. Read Codex local rollout metadata and Claude opt-in statusline cache, validating supported schemas at execution time. Never copy transcripts, tokens or credential values into Nogging logs.

2. Default cap 92%, estimated cost 5% per launch, stale after 600s, unknown warns and continues; on_unknown=deny is available. --ignore-usage-gate is explicit and recorded. Gate execution sessions before worktree allocation, trust changes, tmux or record; exclude bead-less orchestrator and planning by default.

3. The projected cost is current used plus outstanding reserved estimates including the proposed launch, per applicable account bucket. Serialize same-host admission/reservation through an owner-only user-cache ledger keyed by an opaque account identity, release failed/terminal reservations and expire/reconcile dead sessions. Never double-count running_sessions on top of those reservations.

4. Current used can already include part of running costs, so full outstanding estimates are conservative. A gate reduces risk; it does not guarantee a task fits. Document cross-host coordination as unsupported in v1 even with multi_machine; other clients consume quota outside this ledger.

5. Learn estimates only from complete, non-reset, attributable isolated intervals per agent/model; never divide an overlapping account delta by concurrent sessions as if attribution were known. Keep minimum sample count, bounded rolling median and conservative fallback; size labels scale only the reservation estimate.

6. usage install-statusline is an explicit opt-in command. Preserve existing user statusline through a documented composable wrapper or refuse with a manual integration recipe; no silent replacement. Orchestrator schedules bounded retry at the latest limiting reset and does not change model to bypass account limits.

7. Antigravity supplies an additional normalized source in the later runtime change; the reported downstream trial is a reference, not upstream implementation evidence. No runtime model identifiers or prices are hard-coded.

## Dependencies and execution order

Entry task requires TASK-CSL-006. Tasks inside this change form an explicit linear Beads dependency chain; no reliance on tasks.md ordering alone. Cross-change edges are materialized after the planning commit and before execution. This conservative integration order prevents simultaneous edits to scripts/nogg and wrapper contracts.

## Risks / Trade-offs

- Runtime behavior and CLI schemas can change → first validate installed versions and sanitized fixtures; unknown unsupported behavior fails explicitly and becomes a discovery.
- Shared CLI edits can conflict → complete and integrate the prerequisite change into develop before allocating the dependent implementation worktree; a closed task alone does not prove integration.
- Automated mocks can miss interactive failures → final task includes the specified live checks and unsigned evidence; blocked acceptance remains recorded rather than presented as pass.

## Migration Plan

Install through the normal pinned init/update path; preserve consumer-owned state and unrelated configuration. Validate upgrade fixtures before rollout. Roll back tool payload to the previous pinned release without deleting new user-owned state; retain backups required by the scoped migration. Runtime/profile defaults remain unchanged except where the requirements explicitly specify a correction.
