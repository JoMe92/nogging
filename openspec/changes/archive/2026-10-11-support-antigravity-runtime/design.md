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

The Product Owner reprioritized #54 on 2026-10-10. Core runtime support is the next major goal. This supersedes the earlier conservative portfolio order; no normative scenario is removed. AGR-001 still verifies the installed version, official references, prototype and live contracts before implementation. This planning revision makes no runtime acceptance claim.

### Minimal functional prerequisites

| Task | Required foundation | Why remaining SSP/SCM/CSL/GSU work is not a core gate |
| --- | --- | --- |
| AGR-001 | Existing repository/runtime and prototype access | Contract investigation can start now; quota fixtures do not require GSU implementation. |
| AGR-002 | AGR-001; integrated WSS-005 and SSP-003 ownership/role boundary | Canonical locks and planning ownership already exist on develop. SSP-004 is Claude permission guidance, not the agy guard contract. |
| AGR-003 | AGR-002 | agy-native profiles, model forwarding and trust extend the existing wrapper contract. SCM adds Claude/Codex model selection and metadata; it does not provide agy's native --model. AGR-003 implements its already specified agy model forwarding; later SCM work must preserve that path while adding its own profile and metadata behavior. |
| AGR-004 | AGR-003 | Existing session emit/send/stop/kickoff primitives and SSP-001..003 suffice. Exact conversation capture is runtime-specific; CSL corrections are separate work, not a prerequisite for testing these primitives honestly. |
| AGR-006 | AGR-004 | Package the guard, profiles, lifecycle hooks and workflow skills together. Existing installer and payload-contract foundations are integrated; quota installation is added with AGR-005. |
| AGR-007 | AGR-006 | Document the installed core runtime and its limits. Independent SSP documentation work must preserve these additions on integration. |
| AGR-008 | AGR-007 | Exercise installed core runtime, trust, guard, exact resume and real Lead/specialist lifecycle now. No claim of completed quota integration or all of #54. |
| AGR-005 | AGR-004 and GSU-006 | This alone consumes the completed GSU admission/reservation/reset interfaces and, transitively, SCM/CSL/SSP. Include installed quota payload and live integration regression evidence after GSU. |

WSS-005 (SPEC-6t8i), SSP-003 (SPEC-mev1) and sandbox/liveness fix SPEC-2e64 at 0e8257e are already integrated in the planning baseline. AGR-002 explicitly records those foundation edges; AGR-001 has no unfinished prerequisite. No new core agy dependency on SSP-004..006, SCM, CSL or GSU is justified by runtime functionality. Shared edits to scripts/nogg, session-launch, installer and docs are integration risks, not evidence of a missing runtime contract.

### Explicit Beads edge changes

Here `A requires B` means the blocking Beads edge is stored on A with depends_on B. Apply only after the planning commit and materialization; task-list order is not an edge.

- Remove AGR-001 (SPEC-brxc) requires GSU-006 (SPEC-6ajx).
- Remove AGR-006 (SPEC-rv85) requires AGR-005 (SPEC-43k1).
- Add AGR-002 (SPEC-9tfi) requires WSS-005 (SPEC-6t8i), SSP-003 (SPEC-mev1) and SPEC-2e64; all already closed and integrated.
- Add AGR-006 (SPEC-rv85) requires AGR-004 (SPEC-6i8c).
- Add AGR-005 (SPEC-43k1) requires GSU-006 (SPEC-6ajx); retain its AGR-004 prerequisite.
- Retain AGR-002 requires AGR-001, AGR-003 requires AGR-002, AGR-004 requires AGR-003, AGR-007 requires AGR-006 and AGR-008 requires AGR-007. All other SSP/SCM/CSL/GSU task definitions and edges remain intact.

The core path is AGR-001 -> AGR-002 -> AGR-003 -> AGR-004 -> AGR-006 -> AGR-007 -> AGR-008. The existing SSP-004 -> SSP-005 -> SSP-006 -> SCM-001..004 -> CSL-001..006 -> GSU-001..006 backlog chain remains unchanged, and GSU-006 now gates AGR-005 directly; AGR-005 also retains AGR-004. Core agy is the next major execution priority, without an additional blocking edge from SSP-005 to AGR-008: that proposed edge has no functional justification and is unnecessary to make core agy ready. Shared-file integration must be coordinated explicitly rather than represented as an invented runtime prerequisite.

Before allocating each dependent implementation worktree, verify every prerequisite's execution commit is integrated in develop, not just that its Bead is closed. Allocate from updated develop. SSP-004's in-flight worktree must be preserved: serialize integration of shared-file changes, rebase and revalidate any later branch on current develop before fast-forward integration, and preserve both scoped permission guidance and agy changes. Do not invent a functional prerequisite merely to avoid resolving a merge conflict.

### Acceptance and discovery review

AGR-008 records unsigned core runtime acceptance. AGR-005 later adds quota/admission, installed-consumer and live regression evidence, including the core behavior affected by the new pre-trust gate. Until both pass, #54 and the full change remain incomplete and unarchivable; do not advertise quota gating before AGR-005. Human Signed-off-by fields remain blank. Existing capabilities and normative scenarios are unchanged.

Reviewed pending discoveries and the three doctor-ready archives. SPEC-2e64 is fixed in the baseline; SPEC-93hk's Claude quota/reproduction history does not establish an agy dependency. CSL discoveries remain with their existing tasks. Publication/history and other unrelated discoveries remain pending, with no new scope or acknowledgement. Doctor reports PSC/WSS/BMF ready to archive; all three are left intact under the Product Owner's explicit no-archive instruction. No unrelated discovery is acknowledged. No execution Bead is claimed or closed by this planning session.

## Risks / Trade-offs

- Runtime behavior and CLI schemas can change → first validate installed versions and sanitized fixtures; unknown unsupported behavior fails explicitly and becomes a discovery.
- Shared CLI edits can conflict → integrate every prerequisite execution commit into develop before allocating a dependent worktree. Coordinate independent shared-file integrations and revalidate against current develop; Bead closure alone does not prove integration.
- Automated mocks can miss interactive failures → final task includes the specified live checks and unsigned evidence; blocked acceptance remains recorded rather than presented as pass.

## Migration Plan

Install through the normal pinned init/update path; preserve consumer-owned state and unrelated configuration. Validate upgrade fixtures before rollout. Roll back tool payload to the previous pinned release without deleting new user-owned state; retain backups required by the scoped migration. Runtime/profile defaults remain unchanged except where the requirements explicitly specify a correction.
