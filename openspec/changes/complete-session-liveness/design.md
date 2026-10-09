## Context

See proposal.md for the issue scope. Baseline is origin/develop fetched on 2026-10-09. Existing implementation and closed Beads are retained; each task verifies its delta and records evidence.

## Goals / Non-Goals

**Goals:** Deliver every normative scenario in the capability deltas with an installed-consumer regression check and explicit failure behavior.

**Non-Goals:** Reimplement closed Beads, rewrite Git/Dolt history, publish a release, change repository visibility, or sign human acceptance.

## Decisions

1. Treat closed mapped Beads as evidence of existing implementation. Archived dependency-aware-session-launch and session-liveness-and-kickoff retain historical unchecked task lines because their timer mirror did not catch up; do not recreate their tasks. New tasks cover verification and genuine deltas only.

2. Report lifecycle state separately from work state. For lead scope use its assigned task/dependency cone, or explicit authorized change scope recorded at kickoff; specialist scope is exactly one already-claimed Bead. An unrelated blocked sibling must not classify runnable assigned work as blocked.

3. Completion requires mapped tasks in the authorized scope closed and integration evidence. Open/unknown PR status or failed checks prevent change-complete. No-PR workflows require recorded local integration evidence, not simply missing gh output. Network failure is unknown, never merged.

4. session sweep --checks is the explicit remote check path. Cache PR head SHA, check/run fingerprint and last acknowledged observation; doctor uses cache by default and reports stale/unknown without network. session checks-ack records an observation only on explicit operator action and never infers cognition from file mtimes.

5. The #42 correction is authoritative: suggested prompt text is a placeholder, not actual input. Require --message for a nudge unless the adapter can positively identify actual buffered input. Ambiguous pane-only text is unknown and never executed. Explicit nudges replace actual input deliberately and verify submission with one bounded retry.

6. Fresh structured events remain preferred, but stale needs_input contradicted by current pane falls back to live classification; absence of a Stop event cannot pin a resolved permission prompt forever. Retain raw events for diagnosis.

7. Fix SPEC-tbqa ambient NOGG_SESSION_NAME leakage in fixtures; include related discoveries SPEC-hbht, SPEC-icg6 and SPEC-j613. Live runtime tests must exercise two consecutive independent Beads and real first-time trust/profile startup; automated stubs cannot be presented as live acceptance.

## Dependencies and execution order

Entry task requires TASK-SCM-004. Tasks inside this change form an explicit linear Beads dependency chain; no reliance on tasks.md ordering alone. Cross-change edges are materialized after the planning commit and before execution. This conservative integration order prevents simultaneous edits to scripts/nogg and wrapper contracts.

## Risks / Trade-offs

- Runtime behavior and CLI schemas can change → first validate installed versions and sanitized fixtures; unknown unsupported behavior fails explicitly and becomes a discovery.
- Shared CLI edits can conflict → complete and integrate the prerequisite change into develop before allocating the dependent implementation worktree; a closed task alone does not prove integration.
- Automated mocks can miss interactive failures → final task includes the specified live checks and unsigned evidence; blocked acceptance remains recorded rather than presented as pass.

## Migration Plan

Install through the normal pinned init/update path; preserve consumer-owned state and unrelated configuration. Validate upgrade fixtures before rollout. Roll back tool payload to the previous pinned release without deleting new user-owned state; retain backups required by the scoped migration. Runtime/profile defaults remain unchanged except where the requirements explicitly specify a correction.
