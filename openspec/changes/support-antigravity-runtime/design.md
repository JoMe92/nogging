## Context

See proposal.md for the issue scope. Baseline is origin/develop fetched on 2026-10-09. Existing implementation and closed Beads are retained; each task verifies its delta and records evidence.

## Goals / Non-Goals

**Goals:** Deliver every normative scenario in the capability deltas with an installed-consumer regression check and explicit failure behavior.

**Non-Goals:** Reimplement closed Beads, rewrite Git/Dolt history, publish a release, change repository visibility, or sign human acceptance.

## Decisions

1. Revalidate prototype behavior against the installed agy and official CLI reference before coding; capture sanitized hook payloads, real edit/write/shell/URL tool names, quota JSON, denial exit semantics, permission modes and exact-conversation resume. Upstream support is conditional on observed contract, not the issue prototype version alone.

2. Accept --agent antigravity and alias agy normalized in records. .agy.toml profiles accept mode, sandbox, approval and model; reject incompatible profile formats. --read-only selects plan mode but documentation does not claim it is an OS write sandbox. Orchestrator remains Claude-only.

3. A launch without the worktree-local guard payload refuses before trust or tmux. Pre-trust only this explicitly launched owned worktree by atomic merge into ~/.gemini/antigravity-cli/settings.json, preserving keys, entries and mode no wider than 0600. Validate write/trust failure before agent start; no global trust-all setting.

4. Guard uses verified tool args and canonical shared locks from WSS. Malformed payload/unresolvable state denies. At both levels deny the floor and OpenSpec execution writes, including known shell writes/path normalization; allow shell reads. Do not claim the hook is a complete hostile-code sandbox.

5. Restricted refuses global always-proceed or any verified permission mode that defeats ask; return tested ask/force_ask decisions only when they demonstrably prompt. Trusted permits non-floored calls through verified hook behavior. sandbox defaults off until real linked-worktree commit/shared-state acceptance passes; unsupported sandbox mode fails explicitly.

6. Use first-turn prompt and kickoff semantics consistent with existing Codex behavior, keep bare launch non-claiming, disable runtime auto-update per session, capture conversationId on verified hooks and resume only with --conversation. No latest-conversation fallback.

7. Merge only Nogging-named .agents/hooks.json entries and workflow skills nogging-plan/discovery-review/sync-now; preserve user hook order and remove only owned entries on uninstall. Define specialists as separate already-claimed one-Bead sessions, not a new native subagent port.

8. Normalize /usage group/bucket observations into GSU; select the group from chosen model and treat unknown mapping as unknown, check weekly and 5h separately, derive reset from each limiting bucket. Treat headless status/denied_actions as authoritative rather than exit 0 alone.

9. Use reported trial tests as imported fixtures only after review. Full upstream acceptance includes a real Bead lifecycle with validate -> bd close -> nogg task-done -> execution commit -> SHA/evidence note according to canonical instructions; never sign human acceptance.

## Dependencies and execution order

Entry task requires TASK-GSU-006. Tasks inside this change form an explicit linear Beads dependency chain; no reliance on tasks.md ordering alone. Cross-change edges are materialized after the planning commit and before execution. This conservative integration order prevents simultaneous edits to scripts/nogg and wrapper contracts.

## Risks / Trade-offs

- Runtime behavior and CLI schemas can change → first validate installed versions and sanitized fixtures; unknown unsupported behavior fails explicitly and becomes a discovery.
- Shared CLI edits can conflict → complete and integrate the prerequisite change into develop before allocating the dependent implementation worktree; a closed task alone does not prove integration.
- Automated mocks can miss interactive failures → final task includes the specified live checks and unsigned evidence; blocked acceptance remains recorded rather than presented as pass.

## Migration Plan

Install through the normal pinned init/update path; preserve consumer-owned state and unrelated configuration. Validate upgrade fixtures before rollout. Roll back tool payload to the previous pinned release without deleting new user-owned state; retain backups required by the scoped migration. Runtime/profile defaults remain unchanged except where the requirements explicitly specify a correction.
