# Execution log

<!-- nogg:SPEC-9wpk:2026-10-11T08:43:36Z -->
- 2026-10-11T08:56:40+00:00 — SPEC-9wpk closed for TASK-MES-001 (Bead closed at 2026-10-11T08:43:36Z).
  - implementation commits: fa7c4d8bab6c
  - Bead note:
    Non-blocking discovery: the design's Migration Plan says init and update scaffold the model-selection table only when absent, but the installer's update command had no scaffold step at all (only init wrote scaffold files). To meet the plan without changing update behaviour for the other scaffold files (openspec/config.yaml, openspec/project.md, .nogging/config.json), the manifest scaffold entry for templates/model-selection.json now carries onUpdate: true and update scaffolds only entries with that flag. A later planning session may want to state this per-file update scaffolding rule in the spec.
    commit fa7c4d8; scripts/test all green (incl. new scripts/model-selection.test.sh: 36 checks — shipped table valid and complete, 17 invalid-table refusals naming the entry, codex standard lookup, agy alias, --json, no writes, doc/JSON agreement, init scaffold, update keeps an edited table byte-identical and scaffolds an absent one, installed nogg models check). task-done tick applied via the session task-done broker to the shared checkout, not bundled in the commit.
    PR https://github.com/JoMe92/nogging/pull/95 (branch feat/automatic-model-and-effort-selection; #94 closed after the branch-name invariant required the change slug). Required CI green: 30 pass, 2 skipping.
    Non-blocking discovery (tooling, not this change's scope): scripts/nogg pr ci calls 'gh pr checks <url> --json name,state,bucket', but the delivery host's gh rejects --json for pr checks ('unknown flag: --json'). pull_request_ci then sees empty output and reports 'ci_pending (all checks; no runs reported yet)' forever even when every check has finished. PR #95 CI was verified green with plain 'gh pr checks 95' (30 pass, 2 skipping). Either the host gh needs upgrading or pr ci needs a fallback that treats a non-zero exit with unparseable output as a query failure rather than pending.

<!-- nogg:SPEC-wsl3:2026-10-11T09:23:14Z -->
- 2026-10-11T10:14:41+00:00 — SPEC-wsl3 closed for TASK-MES-002 (Bead closed at 2026-10-11T09:23:14Z).
  - implementation commits: 32b2a1158abd
  - Bead note:
    Non-blocking discovery: design decision 4 says an exact-conversation resume keeps its recorded selection and never re-resolves against a changed table, but a resume launch today inherits nothing from the earlier record. Implemented semantics: with --tier and --resume (Claude/Antigravity) the selection is taken from the latest session record of that conversation instead of the table; a different --tier than the recorded one, or a conversation with no recorded tier, refuses before side effects with a remedy (drop --tier). To make that possible for Claude, records also store selection_tier_effort (the tier effort, applied or not) beside selection_tier. A later planning session may want to state this resume rule and the extra field explicitly.
    commit 32b2a11; scripts/test all green, incl. new scripts/session-tier.test.sh (103 checks: per-agent x tier stub argv for Claude --model, Codex --model + --reasoning-effort, Antigravity/agy --model; --model over tier with tier effort kept; tier over profile model/effort; Claude NOTE and no effort flag; unknown tier, missing/invalid table, Pi and planning refusals with no record/settings/tmux/worktree; selection_tier recorded, list tier=, legacy record display unchanged and not rewritten; exact resume keeps recorded model after a table change). task-done tick applied by the session broker to the shared checkout.
    PR https://github.com/JoMe92/nogging/pull/96; CI green (30 pass, 2 skipping).

<!-- nogg:SPEC-ei4z:2026-10-11T10:29:57Z -->
- 2026-10-11T11:55:50+00:00 — SPEC-ei4z closed for TASK-MES-003 (Bead closed at 2026-10-11T10:29:57Z).
  - implementation commits: 0c50a40b5f8f
  - Bead note:
    Non-blocking discovery: design decision 8 compares the installed table_version with the packaged template's, but a consumer install never receives templates/, so doctor cannot read the packaged template there. Implemented as a PACKAGED_MODEL_SELECTION_TABLE_VERSION constant in scripts/nogg (which update overwrites every time), pinned to templates/model-selection.json by scripts/model-selection-drift.test.sh. A planning session that revises the table must bump both together; the test fails if it forgets. Also added an optional config key doctor_agy_models_timeout_seconds (default 15) bounding the agy models probe; TASK-MES-004 may want to document it.
    commit 0c50a40; scripts/test all green, incl. new scripts/model-selection-drift.test.sh (23 checks: present sources give no NOTE; absent Codex and Antigravity models NOTEd by agent/tier/model; catalog absent/malformed and agy not installed/non-zero/timed out (bounded, under 5 s)/empty reported as unavailable, not drift; old and invalid table NOTEs; packaged constant matches the template; full doctor prints the NOTEs with an unchanged exit status). Host doctor: no drift (all 9 table models listed). task-done tick applied by the session broker to the shared checkout.
    Correction to the previous note: the host doctor check covers the 6 Codex and Antigravity table entries (all listed); Claude's 3 entries are only format-checked.
    PR https://github.com/JoMe92/nogging/pull/97; CI green (30 pass, 2 skipping).

<!-- nogg:SPEC-izww:2026-10-11T10:47:19Z -->
- 2026-10-11T11:55:50+00:00 — SPEC-izww closed for TASK-MES-004 (Bead closed at 2026-10-11T10:47:19Z).
  - implementation commits: 1eb9804ddc8e, 0c50a40
  - Bead note:
    commit 1eb9804; tier procedure in orchestrator prompt, /orchestrate, operating-model Orchestration; docs/model-selection.md launch/procedure/quota/drift sections; session+architecture+README docs updated. scripts/model-selection.test.sh new check (docs vs CLI help + procedure in 3 sources) ok; scripts/test exit 0 (all script tests passed).
    PR #98 closed (invariants: branch name must match change dir); reopened from feat/automatic-model-and-effort-selection (fast-forward of merged 0c50a40 to 1eb9804).

<!-- nogg:SPEC-2u2m:2026-10-11T14:09:42Z -->
- 2026-10-11T14:14:44+00:00 — SPEC-2u2m closed for TASK-MES-006 (Bead closed at 2026-10-11T14:09:42Z).
  - implementation commits: 4fc3e90
  - Bead note:
    progress: claimed bead; allocating dedicated worktree
    progress: worktree allocated at /home/jome/src/nogging-spec-2u2m; inspecting task requirements and existing tests
    commit 4fc3e90: verified packed init/update scaffold, tier launch across agents, precedence and refusals in scripts/packed-model-selection.test.sh; recorded acceptance evidence in docs/acceptance/2026-10-11-automatic-model-and-effort-selection.md; full scripts/test green.
