## Context

Facts on `develop` at `fc38f9e` (after archiving `codex-effort-flag`):

- `scripts/nogg` reads `.nogging/config.json` once into `CFG` and the table via
  `load_model_selection()`. `model_selection_entry(table, agent, tier)` returns
  `{agent, tier, model, effort}`; `resolve_launch_tier()` wraps it for launch
  and, for an exact Claude/Antigravity `--resume`, returns the recorded
  `selection_tier_effort` instead of re-reading the table.
- `_session_launch` already orders effort as explicit `--effort` > tier >
  profile > runtime default for Claude and Codex, recording tier-derived effort
  with `reasoning_effort_source` `launch` and `selection_tier_effort` as the
  tier's effort. `session list` prints `effort=<level> (<source>)` and
  `tier=<tier>`.
- `model_selection_notes()` (doctor) computes drift from the table alone.
- `nogg update` scaffolds `.nogging/config.json` only when absent and only
  rewrites `nogging_version` afterwards, so an added key survives.
- Tests: `scripts/model-selection.test.sh`, `session-tier.test.sh`,
  `session-effort.test.sh`, `model-selection-drift.test.sh`,
  `packed-model-selection.test.sh`; fixtures use PATH-injected `bd`/`tmux` and
  `scripts/lib/test-agents.sh` agent stubs. CI has no real agent binaries.

## Decisions

1. **Shape and location.** `tier_overrides` in `.nogging/config.json`:
   `{"<tier>": {"<agent>": {"effort": "<level>"}}}`. Only `effort`; only
   `claude` and `codex`. `antigravity` (effort is in the model name), `pi`,
   `agy`, unknown tiers and unknown keys (for example `model`) are rejected by
   name. Absent or `{}` means no overrides. The block lives in config, not in
   `.nogging/model-selection.json`, because the table is researched data that
   only a planning session revises and `update` never overwrites it; config is
   the project's own settings file and `update` preserves it. The scaffold
   template gains `"tier_overrides": {}` so the key is discoverable.
2. **Validation is pure and shared.** One function
   `tier_overrides_errors(block)` returns offending-key messages
   (`tier_overrides.complex.codex.effort: 'turbo' is not one of …`) using
   `CLAUDE_EFFORTS` and `CODEX_REASONING_EFFORTS`, the same sets `--effort`
   uses. `models check`, `models` lookups, `resolve_launch_tier` and `doctor`
   all call it; none re-implements it. It does not need the table, so it works
   when the table is also broken.
3. **Resolution.** `model_selection_entry(table, agent, tier, overrides=None)`
   keeps returning `model` and `effort` and gains `effort_source`
   (`table` | `project` | `None` for Antigravity) and `table_effort`. The
   override replaces only the effort of exactly the (tier, agent) it names.
   `resolve_launch_tier` returns `effort` (effective), `effort_source` and
   `table_effort`. A malformed block makes `--tier` launches refuse, with a
   remedy (`run scripts/nogg models check`), before any worktree, trust,
   settings, record or tmux side effect; a launch without `--tier` never looks
   at the block. Refusing instead of ignoring a bad block is deliberate: Nogging
   never silently substitutes another effort.
4. **Precedence (explicit wins).** Per field, highest first:
   - Model: explicit `--model` > tier > profile `model` > runtime default
     (unchanged; overrides never touch the model).
   - Claude effort: explicit `--effort` > project override > table > profile
     `effort` > runtime default.
   - Codex effort: explicit `--effort` > project override > table > profile
     `model_reasoning_effort` > runtime default.
   An explicit `--model` alone does not drop the override: `--tier complex
   --model gpt-6-luna` runs Luna at the override effort, exactly as it runs
   Luna at the table effort today. The override is per tier and agent, not per
   model; the Product Owner Codex policy (Luna default) therefore still wants an
   explicit `--effort` or an override that suits Luna.
5. **Attribution.** The record keeps `selection_tier`; `selection_tier_effort`
   is now the *effective tier effort* (identical to today when no override
   exists) and a new `selection_tier_effort_source` is `table` or `project`
   (null for Antigravity and for a null tier). `reasoning_effort_source` keeps
   its vocabulary and gains one value, `project`, used only when the requested
   effort is the override's (no explicit `--effort`); an explicit `--effort`
   stays `launch` even if equal to the override. `session list` therefore shows
   `effort=medium (project) tier=complex`, and the launch confirmation prints
   the same. The ledger keeps its keys: `configured_effort` already holds the
   effective effort and `selection_hash` stays the table-file hash; the
   override's origin is on the session record. Legacy records have no
   `selection_tier_effort_source` and are read as `table`, never rewritten.
6. **Resume.** The existing exact-resume branch returns the recorded
   `selection_tier_effort` and now also the recorded
   `selection_tier_effort_source`; a resume never re-reads `tier_overrides`. A
   Codex resume follows whatever path it takes today for the table effort; the
   implementer reads that path and records in the Bead note whether the override
   is applied or the recorded value is kept, and a test pins whichever is true
   without changing resume behaviour.
7. **`models` display.** Text: `complex  codex  model=gpt-6.1-sol effort=low
   (project; table high)`; unoverridden lines keep today's form. Lookup JSON
   (`--agent`+`--tier`, and the filtered `entries`) gains `effort_source` and
   `table_effort`. The no-filter JSON stays the shipped table unmodified. A
   malformed block makes `models` refuse; `models check` additionally prints
   the override count.
8. **Doctor.** The three existing drift NOTEs are computed from the installed
   table alone and stay independent of overrides (an override cannot change a
   model, so it can neither hide nor create a model-drift finding). Two new
   NOTEs, never failures: a malformed block (first offending key, "tier
   launches refuse until fixed") and a redundant override (equal to the
   installed table's effort for that entry, "can be removed"). The second is
   what Part B produces for projects that adopted the override first. Exit
   status never changes.
9. **Orchestrator.** A Product Owner effort preference is recorded as a project
   override through the normal tracked-change flow (the orchestrator files a
   `routine` Bead naming the exact key and value; a Lead applies it and runs
   `models check`). The orchestrator edits neither the table nor
   `.nogging/config.json`, and never replaces `--tier` with a standing
   `--model`/`--effort` pair. Until the override has landed, `--tier <t>
   --effort <e>` on explicit Product Owner instruction is the interim form and
   keeps `tier=<t>`.
10. **Part B is a separate, decision-gated task.** Changing the shipped
    `complex` defaults needs no spec change (the specs do not pin the values;
    they pin that JSON and docs agree). It edits `templates/model-selection.json`
    (bump `table_version` and `researched_at`), the table and Rationale in
    `docs/model-selection.md`, `PACKAGED_MODEL_SELECTION_TABLE_VERSION` and the
    tests that pin them. Note its real reach: `update` never overwrites an
    installed `.nogging/model-selection.json`, so existing projects keep their
    values and only get the doctor "installed table_version is older" NOTE;
    new installs get the new defaults. The Product Owner decided on 2026-10-19: change
    Codex `complex` (gpt-6.1-sol) from `high` to `low` only; Claude entries stay
    unchanged. The task has no dependency edge.
11. **Tests are failing-first and stub-only.** Each code task writes its test
    first and shows it red before implementing. Launch tests reuse the
    `session-tier.test.sh` fixtures (PATH `bd`/`tmux` stubs and
    `scripts/lib/test-agents.sh` agents) and assert on the recorded wrapper
    argv and session record. No network, no real agent, no real tmux.

## Dependencies and parallel lanes

| Task | Lane (branch) | Needs |
| --- | --- | --- |
| 001 validation, resolution, `models` | `feat/tier-effort-overrides` | none |
| 002 launch, record, list, resume | `fix/tier-effort-overrides` | 001 |
| 003 doctor NOTEs | `refactor/tier-effort-overrides` | 001 |
| 004 operator docs | `docs/tier-effort-overrides` | none |
| 005 orchestrator guidance | `chore/tier-effort-overrides` | none |
| 006 packed install verification | `test/tier-effort-overrides` | 001, 002, 003 |
| 007 Part B shipped defaults | `build/tier-effort-overrides` | none; blocked on decision |

Docs and prompt tasks are string-assertion work written against this design, so
they do not wait for the code. 004 asserts in `runtime-guidance-docs.test.sh`
and 005 in `model-selection.test.sh`, so the two never edit one test file.

## Risks

- Existing assertions pin old wording: `docs/model-selection.md` says tier
  effort is recorded "the table's effort"; `scripts/model-selection.test.sh`
  checks the shipped JSON equals the doc table. Each task updates the
  assertions it changes in the same commit.
- A project that sets an override for a model that does not support the level
  fails at the runtime, visibly, through the normal failed-start path; Nogging
  never retries at another effort.
- `.nogging/config.json` is per checkout; an override only applies to launches
  run from a checkout whose config carries it. The orchestrator launches from
  the main checkout, which is where the tracked change lands.
