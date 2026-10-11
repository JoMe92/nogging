## Context

Research was done once, in this planning session (2026-10-11, baseline develop `8d0e4e6`). The Product Owner ruled that its result is a fixed rule table. The orchestrator classifies a task into a tier and looks the answer up. It does not research models again at launch.

**Live probes on the delivery host**

- **Claude Code 2.1.296.** `claude --help` advertises `--model <alias|full name>` and `--effort <level>` with the levels low, medium, high, xhigh and max. The current Claude family is Fable 5.1, Opus 5.5, Sonnet 5.5 and Haiku 5.5.
- **Codex CLI 0.162.1.** The model catalog (`~/.codex/models_cache.json`) has these entries:

  | Model | Catalog description | Default effort | Supported efforts |
  | --- | --- | --- | --- |
  | `gpt-6.1-sol` | "latest workhorse" | low | low…max, ultra |
  | `gpt-6-astra` | "frontier" | low | low…max, ultra |
  | `gpt-6-sol` | previous workhorse | — | — |
  | `gpt-6-luna` | "fast and affordable … easier tasks" | medium | low…max |

  The host's own `~/.codex/config.toml` uses `gpt-6.1-sol` at `low`. Effort is not limited to low/medium/high: Nogging already validates `none|minimal|low|medium|high|xhigh|max|ultra` for `model_reasoning_effort`.
- **Antigravity 1.3.3.** `agy models` lists:
  - `gemini-3.8-flash-{low,medium,high}`, plus the same three levels for 3.7 Flash and 3.6 Flash;
  - `gemini-3.1-pro-{low,high}`;
  - `claude-sonnet-4-6`, `claude-opus-4-6-thinking` and `gpt-oss-120b-medium`.

  Effort is part of the model name. Per `docs/usage-limits.md`, the Gemini models and the "Claude and GPT models" draw on separate quota groups.

**Web research**

Most of these figures are vendor-reported or come from aggregators, so treat them as directional.

- **Pricing per million tokens (input/output):**
  - Opus 5.5: $4 / $20
  - Sonnet 5.5: $2 / $10
  - Haiku 5.5: $0.10 / $0.50
  - Fable 5.1: about $10 / $50 (one source only)
- **Claude Terminal-Bench 4.0:**
  - Sonnet 5.5: 70.6%
  - Opus 5.5: 66.4%
  - Haiku 5.5: 39.2%
- **Claude positioning:**
  - Anthropic positions Opus 5.5 at Fable 5.1 level on most work.
  - Sonnet 5.5 reaches its scores partly by spending more tokens at high effort.
  - In Claude Code, `max` reportedly scores below `xhigh` on two of three published agentic coding benchmarks and costs 12–15% more.
- **Claude effort guidance:** low for mechanical edits, medium/high for normal feature work, high/xhigh for edge-case debugging and long agentic runs. Claude Code itself defaults to high.
- **GPT-6.1 Sol vs GPT-6 Luna:**
  - Artificial Analysis Intelligence Index: about 52 vs 38.
  - BenchLM coding row: 67.0 vs 51.4.
  - Price per million tokens (input/output): $2 / $10 vs $0.10 / $0.50.
- **Gemini 3.8 Flash:**
  - Google reports Terminal-bench 2.1 90.8% and SWE-Bench Pro 61.6%.
  - Aggregators place 3.8 Flash ahead of 3.1 Pro on coding and agentic tasks.
  - 3.8 Flash defaults to medium thinking; 3.1 Pro offers only low/high in Antigravity.

**Related changes**

- **`support-claude-reasoning-effort` (CRE).** Planned but not implemented: SPEC-hjir, SPEC-agaq, SPEC-mf1y, SPEC-0qpn. It adds Claude `effort` in profiles, a Claude-only public `--effort`, the wrapper `--effort` transport with the `claude-effort-forwarding` capability, and `reasoning_effort_source`. It explicitly rejects public `--effort` for non-Claude agents and does not add a Codex override.
- **`gate-session-usage` (GSU).** Not implemented. It gates launches on quota, keeps model-aware estimates, and forbids model switching as a limit workaround when scheduling resumes.

**Discovery review**

SPEC-hjir is the only open discovery that relates to this change. It is a CRE planning note and needs no spec change here. The other pending discoveries are unrelated and stay pending. `doctor` reported no change ready to archive.

## Goals / Non-Goals

**Goals:**
- One authoritative, versioned table, researched once.
- A mandatory tier classification by the orchestrator for every sub-session it launches.
- Mechanical resolution and honest provenance in `session launch`.
- The Codex and Antigravity parts ship without waiting for CRE; the Claude effort part attaches cleanly when CRE lands.

**Non-Goals:**
- Live re-research at launch time.
- Automatic complexity scoring by Nogging.
- Changing shipped launch-profile defaults or user-global runtime settings.
- Choosing the orchestrator's own model.
- Choosing models for in-process Task-tool subagents.
- A Pi table.
- A public Codex effort flag.
- Quota-driven model switching.
- Implementing CRE or GSU.

## Decisions

1. **The table lives in a data file, not only in prose.**
   - **Location.** Ship `templates/model-selection.json`, scaffolded into consumers as `.nogging/model-selection.json` (written only when absent, like `.nogging/config.json`), so a consumer's edits survive `update`.
   - **Schema.**
     - `schema: 1`.
     - `table_version` and `researched_at`, as ISO dates.
     - `tiers`: exactly `routine`, `standard` and `complex`, each with a one-line `summary` and example task kinds.
     - `agents`: per agent, an entry for every tier. `claude` and `codex` entries have `model` and `effort`. `antigravity` entries have a `model` only, and that name must carry its effort.
   - **Validation.**
     - Tier and agent names come from a fixed set; there are no unknown keys.
     - Every tier is present for every listed agent.
     - Claude effort is one of low, medium, high, xhigh, max. Codex effort is one of `CODEX_REASONING_EFFORTS`.
     - An `effort` key on an Antigravity entry is rejected.
     - Model strings are non-empty and contain no whitespace and no leading `-`.
   - **Printing.** `scripts/nogg models [--agent A] [--tier T] [--json]` prints the table or one lookup. `scripts/nogg models check` validates it and exits non-zero on error.
   - **Prose.** `docs/model-selection.md` mirrors the table with this research and its sources. The JSON is authoritative, and a test asserts the shipped JSON and the doc table agree.
   - **Updates.** Only a planning session revises the shipped table and bumps `table_version`. The orchestrator never edits it.

2. **Three tiers, and the orchestrator chooses the tier.**
   - `routine`: mechanical, fully specified, low blast radius. Examples: docs and text edits, renames, config tweaks, a one-file fix with an obvious test, archive steps, discovery triage, re-running checks.
   - `standard`: a normal feature or bug Bead with a clear spec, multi-file work within one component, or a revision of an existing OpenSpec change. Use it when unsure between routine and standard.
   - `complex`: ambiguous or cross-cutting work. Examples: planning a new capability, architecture, concurrency, locking, security or sandbox work, failure recovery, non-reproducible failures, acceptance runs, and any relaunch after a session failed or stalled on the same task.

   Escalation rules:
   - When unsure, choose the higher tier.
   - A relaunch after failure escalates one tier.
   - Quota never lowers a tier (Decision 6).

   A fourth "trivial" tier was rejected because it would add little over `routine`. Below `routine` the cheapest sensible entries are already in use: Haiku's agentic score is too low for unattended sessions that run tests.

3. **The researched table** (`table_version` 2026-10-11):

   | Tier | Claude (`model` / `effort`) | Codex (`model` / `effort`) | Antigravity (`model`) |
   | --- | --- | --- | --- |
   | routine | `claude-sonnet-5-5` / `low` | `gpt-6-luna` / `low` | `gemini-3.8-flash-low` |
   | standard | `claude-sonnet-5-5` / `high` | `gpt-6-luna` / `medium` | `gemini-3.8-flash-medium` |
   | complex | `claude-opus-5-5` / `xhigh` | `gpt-6.1-sol` / `high` | `gemini-3.8-flash-high` |

   **Claude.**
   - Sonnet 5.5 is the workhorse: it leads Opus on Terminal-Bench at half the price.
   - At `standard` Sonnet runs at Claude Code's own default `high`, because its scores depend on effort. `medium` is the documented cheaper alternative.
   - `complex` uses Opus 5.5 for long-horizon and ambiguous work, at `xhigh`. `max` is excluded as a default: it reportedly scores worse than xhigh on agentic benchmarks and costs more.
   - Haiku 5.5 (39% Terminal-Bench) and Fable 5.1 (about 2.5× Opus price for parity) are excluded.
   - Full model IDs are pinned rather than aliases, so the table does not drift silently.

   **Codex.**
   - `gpt-6-luna` is the default, as the Product Owner steered.
   - Recommendation on low vs medium: **`medium` is the default (`standard`)** and `low` is used only for `routine`. Luna's own catalog default is medium, and its coding score is much weaker than Sol's (about 51 vs 67). Lowering effort on the weaker base model compounds that weakness on anything beyond mechanical work.
   - `complex` moves to `gpt-6.1-sol` at `high`, rather than to the costlier frontier `gpt-6-astra`.

   **Antigravity.**
   - Gemini 3.8 Flash is used at all three tiers. It beats 3.1 Pro on the coding and agentic evidence and offers all three levels.
   - The third-party Claude/GPT models in Antigravity are older and draw on a separate quota group, so they are excluded.

   **Pi** has no table: its model namespace is provider-dependent. `--tier` with `--agent pi` refuses.

4. **`session launch --tier <tier>` resolves the table mechanically.**
   - **Lookup.** Nogging resolves the agent first, using the existing `--agent`/config resolution and normalizing `agy` to `antigravity`, then looks up the entry.
   - **Precedence, per field:**

     | Field | Order (highest first) |
     | --- | --- |
     | Model | explicit `--model` > tier > profile `model` > runtime default |
     | Claude effort | explicit `--effort` (once CRE lands) > tier > profile `effort` > runtime default |
     | Codex effort | tier > profile `model_reasoning_effort` > runtime default |

     An explicit override is the orchestrator's documented exception (Product Owner instruction), not routine use.
   - **Codex transport.** Tier effort travels through the wrapper's existing `--reasoning-effort`. This is not a public Codex `--effort`, so CRE's rule that public `--effort` refuses for Codex stays intact.
   - **Antigravity transport.** The tier model goes through the existing model forwarding.
   - **Refusals.** Each of the following refuses before any worktree, trust, settings, record or tmux side effect, with a remedy:
     - an unknown tier;
     - a missing or invalid table;
     - Pi;
     - an agent with no table entry.
   - **Validation.** The profile's own values are still validated as today.
   - **No fallback.** A runtime that rejects a table model follows the existing failed-start path. There is no silent fallback to another model or effort.
   - **Without `--tier`,** behavior is unchanged.
   - **Resume.** An exact-conversation resume keeps its recorded selection and never re-resolves against a changed table.

5. **Provenance is additive and compatible with CRE.**
   - New records store `selection_tier`: the tier, or null.
   - A tier-derived model or effort uses source `launch`, because it is a launch-time selection. The existing and CRE source vocabularies stay launch, profile and runtime-default, and `selection_tier` says why.
   - `session list` shows `tier=<tier>` for new records and nothing extra for legacy records or records without a tier. Old records stay readable and are never rewritten.

6. **Claude effort attaches later; nothing blocks on CRE.**
   - **Before CRE.** Until CRE's transport and provenance (TASK-CRE-002 and TASK-CRE-003) are integrated, a Claude `--tier` applies the tier model only. It prints a NOTE naming the unapplied effort and the pending change, and records `selection_tier`.
   - **After CRE.** TASK-MES-005, which depends explicitly on TASK-CRE-003, forwards the tier effort through CRE's wrapper `--effort` under its `claude-effort-forwarding` capability negotiation. A stale helper therefore refuses rather than dropping the effort. `reasoning_effort_source` is `launch`.
   - **Ordering.** The Codex and Antigravity work and all documentation ship first.

7. **Interaction with gate-session-usage: a design note, not a dependency.**
   - Complexity decides the tier. Quota decides *when* a session runs and, among agents whose same-tier entry fits, *which* agent runs it.
   - The orchestrator never lowers a tier to dodge a limit.
   - On a GSU denial (exit 75), it waits for the limiting reset as GSU specifies, and does not switch model.
   - A resumed session keeps its recorded agent, model and tier, consistent with GSU's ban on model switching as a limit workaround.
   - Stable per-tier models make GSU's per-agent/model learned estimates more attributable. Mapping tiers to GSU size labels is a possible later alignment, not part of this change.
   - Neither change edits the other's code paths in a conflicting way, so no Beads edge is created.

8. **Drift is reported, never enforced at launch.**
   - `doctor` prints NOTE lines, never failures, when:
     - a Codex table model is absent from the local `models_cache.json`;
     - an Antigravity table model is absent from a bounded `agy models` probe;
     - the installed table's `table_version` is older than the packaged template's.
   - When a source is unavailable, `doctor` says so.
   - Claude has no list command, so Claude entries are only format-checked.
   - Launch performs no live probe: that would be the re-research the Product Owner ruled out.

9. **The orchestrator procedure is mandatory and prompt-borne.**
   - `.nogging/launch-prompts/orchestrator.md` and `docs/operating-model.md` *Orchestration* require three steps before every `session launch` of any role (planning, lead, specialist):
     1. classify the task into a tier with a one-line reason, written to the Bead note or the operator update;
     2. run `scripts/nogg models --agent <agent> --tier <tier>` if needed;
     3. launch with `--tier <tier>`.
   - The `/orchestrate` command points to the same procedure. A Lead Agent that launches an out-of-process specialist may use `--tier` too, but is not required to.
   - Nothing mechanical can verify the classification, so the safeguard is visibility: `tier=` appears in `session list`, and the reason is in the notes.

## Dependencies and execution order

| Bead | Depends on | Why |
| --- | --- | --- |
| TASK-MES-002 | TASK-MES-001 | Serial shared edits in `scripts/nogg` |
| TASK-MES-003 | TASK-MES-002 | Serial shared edits in `scripts/nogg` |
| TASK-MES-004 | TASK-MES-003 | Documents the final flags and NOTEs |
| TASK-MES-005 | TASK-MES-004 | Avoids concurrent doc and launcher edits |
| TASK-MES-005 | TASK-CRE-003 (SPEC-mf1y) | The only cross-change edge; covers CRE-001 and CRE-002 transitively |
| TASK-MES-006 | TASK-MES-004 | Verifies the Codex/Antigravity/doc deliverables without waiting on CRE |

There is no edge to `gate-session-usage`. Every dependent execution worktree starts only after its prerequisite is integrated into develop.

## Risks / Trade-offs

- **Research ages.** Model names and prices change. Mitigations: `table_version`/`researched_at`, the doctor drift NOTEs, and re-research only through a planning session.
- **Vendor-reported benchmarks.** Choices favor robust, cheap-enough defaults, and the rationale is recorded so a later planner can revise it.
- **Misclassification.** The tier is a judgment. The escalation rules and the visible `tier=` provenance mitigate it.
- **Pinned Claude IDs can be retired.** A runtime rejection is visible and fails the launch; the table is then updated through planning.
- **A consumer-edited table can diverge from the packaged one.** That is intended. The version NOTE informs without overwriting.

## Migration Plan

`init` and `update` scaffold the table only when it is absent. Existing launches without `--tier` are unchanged. Rolling back means restoring the older payload. A leftover `.nogging/model-selection.json` is inert to older Nogging; remove `--tier` from operator habits.
