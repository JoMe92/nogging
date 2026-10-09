## Context

See proposal.md for the issue scope. Baseline is origin/develop fetched on 2026-10-09. Existing implementation and closed Beads are retained; each task verifies its delta and records evidence.

## Goals / Non-Goals

**Goals:** Deliver every normative scenario in the capability deltas with an installed-consumer regression check and explicit failure behavior.

**Non-Goals:** Reimplement closed Beads, rewrite Git/Dolt history, publish a release, change repository visibility, or sign human acceptance.

## Decisions

1. Treat both wrappers as verbatim executable tool files in bin/lib/manifest.js and the package payload. Updating deliberately replaces vendored wrappers; customization uses profiles, not edited vendor code.

2. Use a side-effect-free wrapper contract/version handshake (no agent, tmux, Beads mutation or credentials) covering every argv flag emitted by nogg. Prefer one shared declarative flag list; shell and Python may stay separate but contract tests must round-trip all branches.

3. Capture wrapper stderr from process start in the session log; avoid using sleep as a correctness mechanism. A failed preflight creates no session or record; a process failing after creation leaves a terminal failed record with a redacted cause and usable log.

4. Defaulted configuration remains optional. Do not overwrite target-owned config to satisfy self-tests. Installed tests create their own OpenSpec fixtures and resolve installed docs links at the destination depth.

5. Scope includes the #43 comment about claim_stale_seconds, and discoveries SPEC-v8r8 (installed links), SPEC-9s1 (consumer fixtures). No release publication or global configuration changes.

## Dependencies and execution order

Entry task requires no new-change prerequisite. Tasks inside this change form an explicit linear Beads dependency chain; no reliance on tasks.md ordering alone. Cross-change edges are materialized after the planning commit and before execution. This conservative integration order prevents simultaneous edits to scripts/nogg and wrapper contracts.

## Risks / Trade-offs

- Runtime behavior and CLI schemas can change → first validate installed versions and sanitized fixtures; unknown unsupported behavior fails explicitly and becomes a discovery.
- Shared CLI edits can conflict → complete and integrate the prerequisite change into develop before allocating the dependent implementation worktree; a closed task alone does not prove integration.
- Automated mocks can miss interactive failures → final task includes the specified live checks and unsigned evidence; blocked acceptance remains recorded rather than presented as pass.

## Migration Plan

Install through the normal pinned init/update path; preserve consumer-owned state and unrelated configuration. Validate upgrade fixtures before rollout. Roll back tool payload to the previous pinned release without deleting new user-owned state; retain backups required by the scoped migration. Runtime/profile defaults remain unchanged except where the requirements explicitly specify a correction.

## Approved portfolio and issue coverage

The Product Owner delegated all planning choices on 2026-10-09. These eight changes cover all 15 open GitHub issues. Beads is the only executable task tracker; this table is architecture/traceability context.

| Order | Change | Issues | Entry prerequisite | Tasks | Estimate |
| --- | --- | --- | --- | --- | --- |
| 1 | repair-session-payload-contract | #43, #51 | None | 6 | 1–2 person-days |
| 2 | harden-worktree-shared-state | #48, #55 | TASK-PSC-006 | 5 | 1–2 person-days |
| 3 | isolate-bead-mapping-failures | #49 | TASK-WSS-005 | 5 | 2–4 person-days |
| 4 | support-supervised-planning | #47, #52 | TASK-BMF-005 | 6 | 3–5 person-days |
| 5 | configure-session-models | #51 | TASK-SSP-006 | 4 | 1–2 person-days |
| 6 | complete-session-liveness | #37, #38, #39, #40, #41, #42 | TASK-SCM-004 | 6 | 2–4 person-days |
| 7 | gate-session-usage | #53 | TASK-CSL-006 | 6 | 4–7 person-days |
| 8 | support-antigravity-runtime | #54 | TASK-GSU-006 | 8 | 5–10 person-days with reusable prototype |

Issue #51 requires both payload and model-selection changes. Issues #37–#40 require verification of already merged implementation, not duplicate implementation. #41/#42 include genuine corrections to archived behavior. #54 starts only after usage/model/guard foundations integrate. GitHub issue closure requires evidence for every mapped change; the planning session does not close issues.

## Discovery review disposition

All 54 discovery-labeled Beads were reviewed. SPEC-tbqa, SPEC-hbht and SPEC-icg6 feed TASK-CSL-005; SPEC-j613 feeds stale-event reconciliation in the same task. SPEC-v8r8 and SPEC-9s1 feed consumer fixtures/docs checks in PSC. SPEC-i343 informs BMF follow-up semantics. SPEC-b3b and SPEC-vaq inform the corrected planning/acceptance ordering in SSP. Historical resolved identity, installer, archive, rule-grammar and profile discoveries remain evidence; they do not authorize reopening completed work. SPEC-c4o5 remains a separate blocked publication/history decision; no rewrite or visibility work is included. Existing agent-commit-identity Beads remain unchanged and outside this portfolio. Manual clean-machine/bootstrap/UI/public-release acceptance discoveries remain pending for their own acceptance scope. Only discoveries newly addressed by this plan are acknowledged after committed artifacts and materialized replacement tasks exist; unrelated pending review is retained.

## Planning recovery disposition

Six missing-path worktree allocation records were backed up outside the repository after confirming any existing branch tip was integrated into develop; branch refs were retained. The vanished orchestrator record was reaped and retired with Nogging commands. Recovery then reported clear. Three doctor-ready changes were archived based on all mapped Beads being closed; historical unchecked source task lines remain preserved and are not new executable work.

## Validation maintenance

The current OpenSpec CLI strict validator rejects autogenerated Purpose placeholders in 17 legacy main capabilities. This planning session replaces only those placeholder Purpose paragraphs with behavioral summaries; requirements and scenarios are unchanged by that normalization. All portfolio deltas are validated independently and also rehearsed in dependency order through archive in a disposable copy. The existing plain bug SPEC-tbqa is explicitly reconciled into TASK-CSL-005 before materialization to retain its evidence and avoid a duplicate execution task.
