# Model selection

Nogging ships a researched rule table that maps a task's complexity **tier** to
a model, and where the runtime supports it an effort level, for each supported
agent runtime. The orchestrator classifies a task into a tier and looks the
answer up; it does not research models again at launch.

The table is data: `templates/model-selection.json` in the package, scaffolded
into a consumer as `.nogging/model-selection.json` only when that file is
absent, so local edits survive `update`. **The JSON is authoritative**; this
page mirrors it and records why each entry was chosen. A test asserts that the
shipped JSON and the table below agree. Only a planning session revises the
shipped table and bumps `table_version`; the orchestrator never edits it.

## Inspecting the table

```bash
scripts/nogg models                                   # the whole table
scripts/nogg models --agent codex --tier standard     # one lookup
scripts/nogg models --agent agy --tier complex --json # agy = antigravity
scripts/nogg models check                             # validate; non-zero on error
```

`models` reads only the installed table and the project's `tier_overrides` (below). It performs no live model probe and
writes nothing.

## Tiers

- **`routine`** — mechanical, fully specified, low blast radius: docs and text
  edits, renames, config tweaks, a one-file fix with an obvious test, archive
  steps, discovery triage, re-running checks.
- **`standard`** — a normal feature or bug Bead with a clear spec, multi-file
  work within one component, or a revision of an existing OpenSpec change. Use
  it when unsure between routine and standard.
- **`complex`** — ambiguous or cross-cutting work: planning a new capability,
  architecture, concurrency, locking, security or sandbox work, failure
  recovery, non-reproducible failures, acceptance runs, and any relaunch after
  a session failed or stalled on the same task.

Escalation: when unsure, choose the higher tier; a relaunch after failure
escalates one tier; quota never lowers a tier.

## The table

`table_version` 2026-10-19, `researched_at` 2026-10-19.

| Tier | Claude (`model` / `effort`) | Codex (`model` / `effort`) | Antigravity (`model`) |
| --- | --- | --- | --- |
| routine | `claude-sonnet-5-5` / `low` | `gpt-6-luna` / `low` | `gemini-3.8-flash-low` |
| standard | `claude-sonnet-5-5` / `high` | `gpt-6-luna` / `medium` | `gemini-3.8-flash-medium` |
| complex | `claude-opus-5-5` / `xhigh` | `gpt-6.1-sol` / `low` | `gemini-3.8-flash-high` |

Pi has no table: its model namespace depends on the configured provider.

## Schema and validation

- `schema` is `1`; `table_version` and `researched_at` are ISO dates.
- `tiers` has exactly `routine`, `standard` and `complex`, each with a one-line
  `summary` and a non-empty list of `examples`.
- `agents` has exactly `claude`, `codex` and `antigravity`, each with an entry
  for every tier. Claude and Codex entries have `model` and `effort`;
  Antigravity entries have a `model` only, whose name carries the effort. An
  `effort` key on an Antigravity entry is rejected.
- Claude effort is one of `low`, `medium`, `high`, `xhigh`, `max`. Codex effort
  is one of `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`,
  `ultra`.
- Model strings are non-empty and contain no whitespace and no leading `-`.
- Unknown keys and duplicate keys are rejected. `models check` names every
  offending entry.

## Project effort overrides

A project can change the effort of one tier and agent without touching the
researched table. The `tier_overrides` block lives in `.nogging/config.json`
(scaffolded as `"tier_overrides": {}`; `update` preserves it):

```json
{"tier_overrides": {"complex": {"codex": {"effort": "medium"}}}}
```

Shape: `{"<tier>": {"<agent>": {"effort": "<level>"}}}`. Only `effort`, and only
`claude` and `codex`; `antigravity` (effort is in the model name), `pi`, `agy`,
unknown tiers and unknown keys such as `model` are rejected by name. Levels are
the same sets `--effort` accepts. An override replaces only the effort of the
exact tier and agent it names; it never changes a model. Absent or `{}` means no
overrides. `.nogging/config.json` is per checkout, so an override applies to
launches run from a checkout that carries it.

- **Precedence.** explicit `--effort` > project override > table > profile >
  runtime default. `--tier complex --model gpt-6-luna` keeps the override effort.
- **Malformed block.** `session launch --tier` and `models` refuse, with the
  remedy `scripts/nogg models check`, before any worktree, trust, settings,
  record or tmux side effect. Nogging never silently substitutes another effort.
  A launch without `--tier` never reads the block.
- **Display.** `models` prints `effort=low (project; table high)` for an
  overridden entry and the usual form otherwise. Lookup JSON (`--agent` +
  `--tier`, and the filtered `entries`) gains `effort_source` (`table`,
  `project`, or null for Antigravity) and `table_effort`; the unfiltered JSON
  stays the shipped table. `models check` also prints the override count.
- **Doctor.** `doctor` adds two NOTEs, never failures: a malformed block (tier
  launches refuse until fixed) and an override equal to the installed table's
  effort (it can be removed). Model-drift NOTEs are computed from the table
  alone and are unaffected by overrides.

## Launching with a tier

```bash
scripts/nogg session launch --role lead --bead SPEC-xxx --agent codex --tier standard
```

`session launch --tier <tier>` resolves the agent first (the usual `--agent` /
config resolution, `agy` normalized to `antigravity`) and then looks the entry
up in the installed table. Without `--tier`, launch behaves exactly as before.

Precedence, per field (highest first):

| Field | Order |
| --- | --- |
| Model | explicit `--model` > tier > profile `model` > runtime default |
| Claude effort | explicit `--effort` > project override > table > profile `effort` > runtime default |
| Codex effort | explicit `--effort` > project override > table > profile `model_reasoning_effort` > runtime default |

An explicit `--model` or `--effort` over a tier is the orchestrator's documented
exception, used only on Product Owner instruction, not routine use.

- **Codex** receives the reasoning effort through `--effort <level>` (or from the
  tier table, falling back to the profile's `model_reasoning_effort`), forwarded
  via the wrapper's `--reasoning-effort` transport. Launch `--effort` validated
  against `CODEX_REASONING_EFFORTS` overrides the tier effort, and the explicit
  effort is recorded with `reasoning_effort_source` `launch`.
- **Antigravity** receives the tier model, whose name carries the thinking
  level, through the existing model forwarding.
- **Claude** receives the tier model through `--model` and the tier effort
  through the wrapper's `--effort`, which becomes Claude's native `--effort`.
  The effort is recorded with `reasoning_effort_source` `launch`. A helper
  lacking the `claude-effort-forwarding` capability refuses the launch with an
  update remedy instead of silently dropping the effort. An exact `--resume`
  reuses the recorded tier effort.
- **Refusals.** An unknown tier, a missing or invalid table, `--agent pi`, or an
  agent with no table entry refuses with a remedy before any worktree, trust,
  settings, record or tmux side effect.
- **No fallback.** A runtime that rejects a table model follows the normal
  failed-start path; Nogging never silently substitutes another model or
  effort.
- **Resume.** An exact-conversation `--resume` keeps the selection recorded for
  that conversation and never re-resolves against a changed table; a `--tier`
  that differs from the recorded one refuses.

**Provenance.** A new session record stores `selection_tier` (the tier, or
null). When `--tier X --model M --effort E` are passed together, the record keeps
`selection_tier` X and `selection_tier_effort` (the effective tier effort, for usage
attribution) with `selection_tier_effort_source` (`table` or `project`; null for
Antigravity or no tier), while `requested_model` is M and `reasoning_effort` is E, each with
source `launch`. `session list` appends `tier=<tier>` to the `MODEL` cell, for
example `gpt-6-luna effort=medium tier=standard`, or `effort=medium (project)
tier=complex` when the effort came from an override: `reasoning_effort_source`
gains the value `project`, used only when no explicit `--effort` was passed (an
explicit `--effort` stays `launch`, even if equal to the override). An exact
`--resume` keeps the recorded values and never re-reads `tier_overrides`. Legacy
records without `selection_tier_effort_source` read as `table`. Legacy records and records
without a tier show nothing extra and are never rewritten.

## The orchestrator procedure

Before **every** `session launch` of any role (planning, lead, specialist), the
Orchestration Agent:

1. classifies the task into `routine`, `standard` or `complex` and writes a
   one-line reason to the Bead note or the operator update;
2. runs `scripts/nogg models --agent <agent> --tier <tier>` if it needs to see
   the entry;
3. launches with `--tier <tier>`.

It takes model and effort from the table, never from live research, and applies
the escalation rules: when unsure, the higher tier; a relaunch after a failed or
stalled attempt escalates one tier; quota never lowers a tier. The procedure is
stated in `.nogging/launch-prompts/orchestrator.md`, the `/orchestrate` command
and `docs/operating-model.md` *Orchestration*, so a fresh orchestrator applies
it without memory of earlier conversations. A Lead Agent that launches an
out-of-process specialist may pass `--tier` too, but is not required to.

### Product Owner Codex cost policy

Under the Product Owner's Codex cost policy:
- Codex defaults to `gpt-6-luna` across tiers;
- `gpt-6.1-sol` is used only with effort `low` and only for extremely hard tasks,
  on explicit Product Owner instruction.

When overriding model or effort under this policy, the orchestrator passes the
overrides together with the honest `--tier` so attribution is preserved:
- Default Luna spelling: `scripts/nogg session launch --tier <tier> --model gpt-6-luna --effort <level>`
- Sol exception for extremely hard tasks: `scripts/nogg session launch --tier <tier> --model gpt-6.1-sol --effort low`

Nothing mechanical can verify a classification, so the safeguard is
visibility: `tier=` in `session list` and the reason in the notes.

## Quota and tiers

Complexity decides the tier. Quota decides **when** a session runs and, among
agents whose same-tier entry fits, **which** agent runs it. The orchestrator
never lowers a tier to dodge a limit: on a usage-limit denial it waits for the
limiting reset, or launches the same tier on another agent. A resumed session
keeps its recorded agent, model and tier; switching model is not a limit
workaround. See `docs/usage-limits.md`.

## Drift

`scripts/nogg doctor` prints `NOTE model-selection: …` lines, never failures,
when a Codex table model is absent from the local Codex model catalog
(`models_cache.json`), when an Antigravity table model is absent from a bounded
`agy models` probe, or when the installed `table_version` is older than the
packaged one (`update` never overwrites `.nogging/model-selection.json`;
merge the new entries by hand). An unavailable source is reported as
unavailable, not as drift. Claude has no list command, so Claude entries are
only format-checked. Launch never probes live: a drifted entry is revised in a
planning session.

## Rationale

The research was done once, in the planning session of 2026-10-11. Most
benchmark and price figures are vendor-reported or come from aggregators, so
treat them as directional.

**Claude.** Sonnet 5.5 is the workhorse: it leads Opus 5.5 on Terminal-Bench
4.0 (70.6% vs 66.4%) at half the price ($2 / $10 vs $4 / $20 per million input
/ output tokens). At `standard` it runs at Claude Code's own default `high`,
because its scores depend on effort; `medium` is the documented cheaper
alternative. `complex` uses Opus 5.5 for long-horizon and ambiguous work at
`xhigh`; `max` is excluded as a default because it reportedly scores below
`xhigh` on agentic coding benchmarks and costs 12–15% more. Haiku 5.5 (39.2%
Terminal-Bench) is too weak for unattended sessions that run tests, and Fable
5.1 costs about 2.5× Opus for parity. Full model IDs are pinned rather than
aliases, so the table does not drift silently.

**Codex.** `gpt-6-luna` is the default, as the Product Owner steered. `medium`
is its `standard` effort and `low` is used only for `routine`: Luna's own
catalog default is medium and its coding score is much weaker than Sol's
(BenchLM about 51 vs 67), so lowering effort compounds that weakness on
anything beyond mechanical work. `complex` moves to `gpt-6.1-sol` (the
catalog's "latest workhorse"), rather than the costlier frontier
`gpt-6-astra`. Per the Product Owner decision on 2026-10-19, it keeps that
model but uses `low` effort. Effort reaches Codex as its `model_reasoning_effort`.

**Antigravity.** Gemini 3.8 Flash is used at all three tiers: it beats 3.1 Pro
on the coding and agentic evidence (Google reports Terminal-bench 2.1 90.8% and
SWE-Bench Pro 61.6%) and offers all three thinking levels, whereas 3.1 Pro
offers only low/high in Antigravity. The third-party Claude and GPT models in
Antigravity are older and draw on a separate quota group, so they are excluded.

## Sources

- Live probes on the delivery host: `claude --help` (Claude Code 2.1.296),
  the Codex model catalog `~/.codex/models_cache.json` (Codex CLI 0.162.1),
  and `agy models` (Antigravity 1.3.3).
- Vendor pricing and benchmark pages, the Artificial Analysis Intelligence
  Index and the BenchLM coding row, as summarized in the planning design of the
  `automatic-model-and-effort-selection` change.
- `docs/usage-limits.md` in the Nogging repository for the Antigravity quota
  groups.
