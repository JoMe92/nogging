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

`models` reads only the installed table. It performs no live model probe and
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

`table_version` 2026-10-11, `researched_at` 2026-10-11.

| Tier | Claude (`model` / `effort`) | Codex (`model` / `effort`) | Antigravity (`model`) |
| --- | --- | --- | --- |
| routine | `claude-sonnet-5-5` / `low` | `gpt-6-luna` / `low` | `gemini-3.8-flash-low` |
| standard | `claude-sonnet-5-5` / `high` | `gpt-6-luna` / `medium` | `gemini-3.8-flash-medium` |
| complex | `claude-opus-5-5` / `xhigh` | `gpt-6.1-sol` / `high` | `gemini-3.8-flash-high` |

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
catalog's "latest workhorse") at `high`, rather than the costlier frontier
`gpt-6-astra`. Effort reaches Codex as its `model_reasoning_effort`.

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
