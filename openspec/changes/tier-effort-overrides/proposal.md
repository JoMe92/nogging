## Why

GitHub issue #252: the shipped `complex` tier maps to the most expensive
efforts (Claude `claude-opus-5-5` / `xhigh`, Codex `gpt-6.1-sol` / `high`). For
the work that lands in `complex` on a small host with several parallel leads,
the Product Owner's standing decision is Opus at `medium` and Sol at `low`.

Since #229 an operator can pass `--tier complex --effort medium`, which keeps
`tier=complex` in the record. But that is a per-launch exception: every launch
must repeat it, and the orchestrator prompt reserves explicit `--model` and
`--effort` for one-off Product Owner instructions. There is no place to record
a *standing* effort preference for a project, and the orchestrator must not
edit the shipped table. The workaround in practice is to bypass the tier, which
loses the honest attribution that `session list` and usage accounting rely on.

## What Changes

Part A (planned and ready to execute):

- A per-project `tier_overrides` block in `.nogging/config.json`, keyed by tier
  then agent (`claude`, `codex`), each holding only an `effort`. It is applied
  after the installed table is read, validated against the same effort sets as
  `--effort`, and never changes a model.
- Effort precedence for a tiered launch becomes explicit `--effort` > project
  override > table > profile > runtime default. Explicit `--model` and
  `--effort` keep winning, so `--tier X --model M --effort E` still records the
  tier and the override.
- Honest attribution: the record gains `selection_tier_effort_source`
  (`table` | `project`), a tier effort that came from an override has
  `reasoning_effort_source` `project`, and `models` and `session list` show
  `effort=<level> (project)`.
- `models check` validates the block; `doctor` gains NOTEs for a malformed
  block and for a redundant override, and the existing model-drift NOTEs are
  specified to be independent of overrides.
- Docs and the orchestrator guidance: a Product Owner effort preference is
  recorded as a project override, never by bypassing `--tier`.

Part B (planned, **not ready**, Decision needed from the Product Owner):

- One task to change the *shipped* `complex` default for Codex only (`high` to
  `low`; Claude stays `xhigh`), per the Product Owner decision of 2026-10-19.
  It has no dependency edge.

## Non-goals

- No change to `templates/model-selection.json` or its `table_version` in
  Part A. Part B is the only task that may touch the shipped values, and only
  after the Product Owner decides.
- No model override (`tier_overrides` takes `effort` only), no Antigravity or
  Pi override, no per-model override, no per-session or per-role override.
- No new command for editing the block; it is a tracked config edit validated by
  `models check`.
- No change to usage-ledger schemas: attribution keeps `configured_effort`
  (already the effective effort) and the table `selection_hash`.
- No enforcement of the Product Owner Codex policy (Luna default, Sol only with
  `low`); it stays guidance, as set in #226.

## Impact

- Capabilities: `model-selection` (override requirement, lookup, launch,
  record, doctor), `launch-profiles` (effort provenance gains `project`),
  `orchestration-agent` (guidance).
- Code: `scripts/nogg` (config validation, `model_selection_entry`,
  `resolve_launch_tier`, `_session_launch`, `models`, session list, doctor),
  `templates/nogging-config.json`, tests under `scripts/`, docs, and the
  orchestrator prompt and command.
