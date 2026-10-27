## Why

Which agent implements a task is a user decision that Nogging cannot express
today. `session launch` takes `--agent` or the single `session_agent` key, and
the Orchestration Agent picks an agent from prose rules. Worse, one operator's
personal preference is written into files Nogging ships: the orchestrator
launch prompt, the `/orchestrate` command and three docs pages tell every
consumer to run Codex on `gpt-6-luna` and `gpt-6.1-sol` only at `low` effort.

On 2026-10-27 the Product Owner (Jonas) asked for implementation work to go to
Pi with Z.ai GLM on the herdr backend first, then Codex when its usage windows
allow, then Claude. In the same breath he asked that this not be hardcoded:
it is his configuration, and every user must be able to set their own order.

## What Changes

- Add an ordered, per-role agent routing file (`.nogging/agent-routing.json`
  by default, relocatable with the new `agent_routing_file` key). Each entry
  names an agent and optionally a backend, eligible tiers, per-tier model and
  effort, a model allow-list with a note, and an `on_unknown` usage policy. A
  missing file means no routing, so every existing install launches exactly as
  before.
- `session launch` without `--agent` walks the role's list before any side
  effect and launches the first admitted entry. An entry is skipped, with a
  recorded reason, for an operator skip, a tier filter, a missing CLI, missing
  authority, an unavailable backend, a disallowed model or a usage-gate
  refusal. Only the chosen entry reserves usage headroom. When every entry is
  skipped the launch refuses, with exit 75 when waiting for a usage reset
  would help.
- `--agent` pins the launch to that agent's entry, so its models and
  allow-list still apply but there is no fall-through. An agent that is not
  listed launches exactly as today. `--skip-agent` excludes an agent for one
  routed launch.
- Tiers stay mandatory for the orchestrator and are never lowered. Agents
  without a model-selection table (Pi) accept and record a tier when routing
  lists them. Model and effort that come from an entry are recorded with the
  new source `route`.
- The decision is visible. The session record gets a `routing` block, launch
  prints a `routing=` line for the Bead note, and `session list` shows the
  chosen entry and every skipped one. `nogg route` previews the decision
  read-only, and `nogg route check`, `validate` and `doctor` validate the file.
- Shipped prompts, commands and docs drop the Product Owner's Codex wording
  and instead tell agents to follow the project's routing configuration. A
  regression test keeps that wording out of shipped files.
- This repository then sets its own preference in a host-local, untracked
  routing file (`.nogging/state/agent-routing.json`, through
  `agent_routing_file`). Leads and specialists use Pi/GLM on herdr, then Codex
  on herdr only when its usage is known and fits (Luna, `complex` at medium,
  Sol only at low effort with the note "extremely hard tasks only"), then
  Claude on herdr. Planning stays on Claude. The shipped model-selection table
  is unchanged.

## Capabilities

### New Capabilities

- `agent-routing`: the routing file, its validation, the routed, pinned and
  off-list launch modes, per-entry model and effort resolution, decision
  visibility, the `nogg route` preview and the generic shipped guidance.

### Modified Capabilities

- `agent-neutral-launch`: the agent of a launch without `--agent` comes from
  the role's routing list when one is configured, and from `session_agent`
  only otherwise.
- `model-selection`: an entry can supply the tier model and effort (precedence
  and the `route` source). A tier is accepted and recorded for a table-less
  agent that routing lists.
- `orchestration-agent`: the tier procedure follows the project's routing
  instead of the shipped Codex cost policy.

## Impact

Code: `scripts/nogg` (launch, `route`, `models`, `session list`, `doctor`),
the new shipped module `scripts/lib/agent_routing.py`, `scripts/nogg_usage.py`
(a read-only admission check), `templates/nogging-config.json` and
`bin/lib/manifest.js`. Prompts and docs: `.nogging/launch-prompts/orchestrator.md`,
`.claude/commands/orchestrate.md`, `docs/operating-model.md`,
`docs/model-selection.md`, `docs/using-with-codex.md`, `docs/configuration.md`,
`docs/commands.md`, `docs/running-work-in-sessions.md`, `docs/using-with-pi.md`,
`AGENTS.md` and `CHANGELOG.md`. Tests: new routing suites plus updates to
`scripts/runtime-guidance-docs.test.sh`.

Existing installs need no migration. Without a routing file, launches, records
and `session list` output stay byte-for-byte as before. Consumers who followed
the shipped Codex wording get an upgrade note with an equivalent routing file.

This change does not route the Orchestration Agent's own runtime
(`dual-runtime-orchestrator` owns that), does not let scheduled-loop launches
route, does not change the shipped model-selection table, and does not add a
usage source for Pi.
