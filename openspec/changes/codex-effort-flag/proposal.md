## Why

GitHub issue #226: Codex has no launch flag for reasoning effort. `--effort`
is documented and validated as Claude-only, and with `--tier` the table effort
beats the profile's `model_reasoning_effort`. An operator who wants "this
model at low effort" has to hand-write a profile TOML and launch without
`--tier`, which loses tier attribution.

The Product Owner set a Codex cost policy on 2026-10-18 after three Codex
Leads on `--tier complex` (`gpt-6.1-sol`, effort high) used up the 5-hour
Codex window in about 25 minutes:

- Codex defaults to `gpt-6-luna`.
- `gpt-6.1-sol` is used only with effort `low`, and only for extremely hard
  tasks.

Today that policy needs `--model gpt-6-luna` (which wins over the tier model)
for Luna and a hand-written profile for Sol-low.

## What Changes

- `session launch --effort <level>` is accepted for Codex. It is validated
  against the existing Codex effort set, forwarded through the wrapper's
  `--reasoning-effort`, and overrides the tier effort the same way `--model`
  overrides the tier model. Claude behaviour is unchanged. Pi and Antigravity
  still refuse it.
- `--tier X --model M --effort E` work together. The tier stays recorded as
  `selection_tier` for attribution while model and effort follow the explicit
  values. Each field records its own source.
- Docs and the orchestrator guidance state the Luna-default / Sol-low-only
  policy and the exact command spelling.

## Non-goals

- No change to `templates/model-selection.json` or its `table_version`. The
  table keeps `gpt-6.1-sol` / `high` for Codex `complex`; the policy is applied
  with explicit overrides on the Product Owner's instruction, as the
  orchestrator procedure already requires. Revisiting the table, or adding a
  per-repo overlay such as `.nogging/model-selection.local.json` (the optional
  third proposal in #226), is a separate planning decision.
- No new wrapper capability and no new public Codex flag. The wrapper's
  existing `--reasoning-effort` transport is reused.
- No mechanical enforcement of the policy. Like tier classification, it is
  guidance plus visibility (`tier=` and `effort=… (launch)` in `session list`).

## Impact

- Capabilities: `launch-profiles` (effort flag), `model-selection` (tier plus
  explicit overrides), `orchestration-agent` (launch guidance).
- Code: `scripts/nogg` (`_session_launch`, `--effort` help), tests under
  `scripts/`, docs, `.nogging/launch-prompts/orchestrator.md`,
  `.claude/commands/orchestrate.md`.
