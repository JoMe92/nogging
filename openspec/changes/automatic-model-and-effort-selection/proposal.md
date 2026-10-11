## Why

The Orchestration Agent launches every Planning, Lead and specialist session. Today it picks no model and no reasoning effort, so each session either inherits a runtime default or uses whatever the Product Owner asked for that time. The cost/quality trade-off is redone by hand, or not at all. The Product Owner wants this decision to be a standing, documented part of the workflow. A fresh orchestrator with no memory of earlier conversations must apply it to every launch.

The Product Owner also ruled that model research happens **once, in planning**. The result is a fixed rule table: complexity tier × agent → model + effort. At launch time the orchestrator makes one judgment call — which tier the task falls into — and then looks the answer up mechanically. It does not research models again at launch.

## What Changes

- Ship a researched, versioned rule table `.nogging/model-selection.json`, with three tiers (`routine`, `standard`, `complex`), a concrete model and effort per tier for Claude, Codex and Antigravity, and a dated rationale. The table is scaffolded into consumers and remains editable by them.
- Add `scripts/nogg models` to print and validate the table, and add a `doctor` NOTE when a table model is missing from the live runtime model list or when the installed table is older than the packaged one.
- Add `scripts/nogg session launch --tier <tier>`, which resolves the table entry for the resolved agent. Explicit `--model` and an explicit effort override take precedence over the tier, and the tier takes precedence over the profile. The selected tier is recorded and listed.
- For Codex, tier effort travels on the wrapper's existing `--reasoning-effort` transport. For Antigravity, the effort is part of the model name. For Claude, tier effort is applied only once the `support-claude-reasoning-effort` transport is integrated. Until then a Claude tier applies the model only and says so.
- Require the orchestrator to classify every sub-session launch into a tier and pass `--tier`. Document the procedure in the orchestrator launch prompt and in `docs/operating-model.md`, and document the table and its research in a new `docs/model-selection.md`.

## Capabilities

### New Capabilities

- `model-selection`: the tier rule table, its validation and printing, tier-resolved launch selection and its provenance.

### Modified Capabilities

- `orchestration-agent`: adds a required tier classification for every launch.

## Impact

Execution will touch `scripts/nogg`, `templates/` and the installer manifest, the orchestrator launch prompt, the `/orchestrate` command, operating-model, architecture and session docs, and a new `docs/model-selection.md`, along with focused and installed-payload tests. No new dependencies are needed. Nothing in user-global runtime configuration is written. Shipped launch profiles keep their current defaults.

Related changes:
- `support-claude-reasoning-effort`: only the Claude-effort task has an explicit dependency on it.
- `gate-session-usage`: a design interaction with no dependency edge.

This change plans implementation only.
