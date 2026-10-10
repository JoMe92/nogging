## Context

See proposal.md for the issue scope. Baseline is origin/develop fetched on 2026-10-09. Existing implementation and closed Beads are retained; each task verifies its delta and records evidence.

## Goals / Non-Goals

**Goals:** Deliver every normative scenario in the capability deltas with an installed-consumer regression check and explicit failure behavior.

**Non-Goals:** Reimplement closed Beads, rewrite Git/Dolt history, publish a release, change repository visibility, or sign human acceptance.

## Decisions

1. Canonical CLI: --role planning, --planning-id <kebab> --description <kebab>; --bead is optional and does not become execution authority. No planner alias in v1. Allocate a fresh dedicated planning worktree through the existing primitive; reject arbitrary shared-checkout planning execution.

2. Launching creates a supervised idle session, not a planning lock. The role-specific kickoff instructs that same session to acquire plan-begin before its first spec write. This retains the launch checkpoint and lets the actual writer own the lock. Orchestrator must never pre-acquire it for a child.

3. A supervised planning lock carries session identity plus host/process ownership. Stop/cleanup must not close another session lock; crash recovery reports the exact stale owner and restores a closed boundary only after verified ownership/liveness. Two planning kickoffs race on the same canonical lock, so only one can write.

4. Planning prompt sequence: worktree -> plan-begin -> discoveries -> ready archives -> author -> validate -> planning commit -> materialize -> explicit dependency wiring -> local fast-forward integration -> safe cleanup -> plan-end. Release/close from a surviving canonical checkout after verifying the owned worktree is clean and integrated; never call a script in a removed directory.

5. Use per-session Claude effective settings for scoped ./scripts/nogg session launch/send/kickoff/stop/list/log/watch rules. Installer merges only named Nogging hook/instruction entries, never globally enables bypass or changes user auto mode. Direct codex/claude/pi fallback launches and service installation are not authorized by these rules.

6. Reproduce #52 with installed runtime/help before asserting classifier behavior. If scoped rules cannot authorize child creation in a supported auto mode, report an actionable unsupported combination and document explicit operator-selected trusted/orchestrator profile. Never emulate consent or auto-install persistent services.

7. Consult docs/architecture.md inline; no architect execution session is needed for this planning-only request. Reconcile source, templates and all three command surfaces, including README commit-before-materialize discovery SPEC-b3b.

## Dependencies and execution order

Entry task requires TASK-BMF-005. Tasks inside this change form an explicit linear Beads dependency chain; no reliance on tasks.md ordering alone. Cross-change edges are materialized after the planning commit and before execution. This conservative integration order prevents simultaneous edits to scripts/nogg and wrapper contracts.

## Risks / Trade-offs

- Runtime behavior and CLI schemas can change → first validate installed versions and sanitized fixtures; unknown unsupported behavior fails explicitly and becomes a discovery.
- Shared CLI edits can conflict → complete and integrate the prerequisite change into develop before allocating the dependent implementation worktree; a closed task alone does not prove integration.
- Automated mocks can miss interactive failures → final task includes the specified live checks and unsigned evidence; blocked acceptance remains recorded rather than presented as pass.

## Migration Plan

Install through the normal pinned init/update path; preserve consumer-owned state and unrelated configuration. Validate upgrade fixtures before rollout. Roll back tool payload to the previous pinned release without deleting new user-owned state; retain backups required by the scoped migration. Runtime/profile defaults remain unchanged except where the requirements explicitly specify a correction.
