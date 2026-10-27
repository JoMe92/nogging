## Context

The Product Owner (Jonas) made this request on 2026-10-27, verbatim in German:

1. "ok ich will das ab jetzt pi mit glm als stanadrd verwendet wird mit herdr
   backend ancha codex wen was frei ist udn dan erst vclaud um aufgaben
   umzusetzen bitte merke dir das"
2. "das soll aber nicht las code uauusgeliefert werden das ist eine
   konifuration di efür mich ist ander solen das anders kofigurernen
   köenen..... daher das sol nicht dirket ind en code hasrdgecodet sein der
   nutzer sol da ein preisisierung festelgenen köenmen"

In English: from now on, implementation work goes to Pi with GLM on the herdr
backend by default, then to Codex when it has capacity, and only then to
Claude. That is his own configuration and must not ship as code. Other users
must be able to configure their own priority.

Facts gathered while planning, on `develop` at `a42e3a2`:

- **Agent selection.** `resolve_agent()` takes `--agent`, then
  `session_agent`, then `claude`. Nothing in Nogging orders agents or falls
  back between them. The orchestrator picks an agent from prompt rules, and
  the current preference lives only in its `bd remember` memory
  (`lead-agent-routing`).
- **Backends.** `session_backend` (default `tmux`) or `--backend` selects the
  substrate. `choose_launch_backend()` pins the orchestrator to tmux. The herdr
  backend's read-only `preflight(agent)` refuses agents outside
  `_RECORDER_AGENTS` (claude, codex, antigravity, pi), a missing herdr binary
  and a recorder that fails its contract.
- **Refusals before side effects.** `_session_launch()` checks these in order:
  agent binary (`require_agent_binary`), planning authority for Codex and
  Antigravity, `--effort` validity, `--tier` resolution, backend preflight,
  profile and spec loading, model and effort precedence, Bead existence and
  unmet dependencies. Last comes `usage_gate_admission()`, the only step that
  reserves headroom. A denial raises `UsageGateDenied` (exit 75).
- **Tiers.** `.nogging/model-selection.json` has entries for claude, codex and
  antigravity. `resolve_launch_tier()` refuses Pi ("its model namespace is
  provider-dependent"). The precedence is explicit flag, then the project
  `tier_overrides` effort, then the table, then the profile, then the runtime
  default. The shipped Codex column is Luna `low`/`medium` and Sol `low` for
  `complex` (TASK-TEO-007). Pi takes its model from `--model`, a `.pi.toml`
  `model` or its own `~/.pi/agent/settings.json`.
- **Usage.** `nogg_usage.GATE_AGENTS` includes `pi`, but Pi has no usage
  source, so `observe('pi')` reports unknown. Under the default
  `on_unknown: "warn"` an unknown agent is admitted with a WARN. Codex reads
  its account-wide 5-hour and weekly windows from rollout files. Planning and
  orchestrator launches are excluded from the gate by default.
- **The personal policy in shipped files.** The sentence "Under the Product
  Owner's Codex cost policy ... `gpt-6-luna` ... `gpt-6.1-sol` only with effort
  `low`" appears in `.nogging/launch-prompts/orchestrator.md`,
  `.claude/commands/orchestrate.md`, `docs/operating-model.md`,
  `docs/model-selection.md` (its own section plus rationale wording) and
  `docs/using-with-codex.md`. `bin/lib/manifest.js` ships all five to
  consumers. The `orchestration-agent` spec has a scenario "Codex cost policy
  is applied", and `scripts/runtime-guidance-docs.test.sh` *requires* the Luna
  and Sol spellings in `using-with-codex.md`. This repository's own
  `.nogging/config.json` is not shipped (the installer scaffolds
  `templates/nogging-config.json`).
- **Config validation surfaces.** `nogg validate` is `doctor` without
  `--audit`: FAIL lines set the exit code, WARN and NOTE lines do not.
  `scheduled-loops` (in flight) wires an invalid `loops_file` to FAIL and moves
  this repository's loops host-local through a config key (its Product Owner
  decision 1). `scripts/docs-site.test.sh` requires `docs/configuration.md` to
  document every template key and every literal `scfg()` key.
- **Changes in flight.** `scheduled-loops` TASK-SCL-008 edits the same
  orchestrator prompt and command. `dual-runtime-orchestrator` changes the
  orchestrator runtime and may add a Codex orchestrator entry point. In
  `branded-docs-site`, TASK-BDS-011 (sessions pages, in progress) and
  TASK-BDS-012 (usage limits, open) touch neighbouring docs. None of them
  modifies the `orchestration-agent` tier requirement or the
  `model-selection` requirements this change modifies.
- **Discoveries.** `nogg discoveries` lists 149 pending discoveries. None is
  about agent routing or agent priority, so none is carried into this change
  and none is acknowledged here.

## Goals / Non-Goals

**Goals:** a user-owned, ordered agent priority per role, expressed as data.
Launches follow it mechanically before any side effect, never lower a tier,
and show which entry ran and why higher entries were skipped. Model and effort
constraints, such as "Luna by default, Sol only at low effort for extremely
hard tasks", can be written as data. Shipped files carry no personal
preference, and existing installs see no change until they opt in.

**Non-Goals:** routing the Orchestration Agent's own runtime
(`dual-runtime-orchestrator` owns it); routing scheduled-loop launches, which
keep their explicit agent and tier; a usage source for Pi or Z.ai; changing the
shipped model-selection table; re-routing after a session started; automatic
relaunch on another agent when a running session hits a runtime limit.

## Decisions

### Decision 1: Test and execution discipline

Every suite runs offline inside `scripts/test`. No Dolt, no `bd`, no shared
tmux or herdr server, no real agent CLI and no network. Suites source
`scripts/lib/test-env.sh` and use stub agent binaries on a private `PATH`, the
existing fake herdr and stub tmux fixtures, and injected usage observations.
They assert refusals by the absence of records, logs, worktrees and
reservations. The decision engine is a pure module with injected probes, so
its order and reason codes are unit-tested without a launch. Live checks
appear only in TASK-RTG-008, in a disposable scratch consumer repository with
a private tmux socket. Fixtures and docs contain no email address, and the
owner is named only as Jonas or JoMe92.

### Decision 2: One routing file, located by `agent_routing_file`

Routing lives in its own JSON file, by default `.nogging/agent-routing.json`.
The repository-relative config key `agent_routing_file` can move it, for
example under `.nogging/state/` to keep it host-local and untracked. The path
resolves against the repository's main checkout
(`canonical_repository_state`), so a launch from a linked worktree reads the
same file as the canonical checkout. A missing file means no routing. The
installer never writes the file and `update` never touches it. The template
gains the key with its default value, so the docs-site key-coverage check
documents it.

*Why a file and not a `.nogging/config.json` block:* it follows the two
nearest precedents, `.nogging/model-selection.json` (a versioned table) and
`loops_file` (relocatable to host-local). It carries its own `schema_version`,
and a user can keep a personal order out of a shared repository without
forking `config.json`.

### Decision 3: Schema

```json
{
  "schema_version": 1,
  "roles": {
    "lead": [
      {"agent": "pi", "backend": "herdr"},
      {"agent": "codex", "backend": "herdr", "on_unknown": "deny",
       "models": {"complex": {"model": "gpt-6-luna", "effort": "medium"}},
       "allow": [{"model": "gpt-6-luna"},
                 {"model": "gpt-6.1-sol", "efforts": ["low"],
                  "note": "extremely hard tasks only"}]},
      {"agent": "claude", "backend": "herdr"}
    ],
    "planning": [{"agent": "claude"}]
  }
}
```

- `roles` keys are `lead`, `specialist` (every `specialist:<type>`) and
  `planning`. `orchestrator` is refused with a pointer to the orchestrator
  commands. An absent role is unrouted. An empty list is refused, and the
  remedy is to remove the key.
- An entry has a required `agent` (`claude`, `codex`, `pi`, `antigravity`;
  `agy` is normalized). It may also have:
  - `backend`: `tmux` or `herdr`. When absent, the launch uses the
    configured `session_backend`.
  - `tiers`: a non-empty subset of `routine`, `standard` and `complex`. The
    entry is eligible only for those tiers. Absent means all tiers.
  - `models`: keyed by tier, each value `{model?, effort?}` with at least one
    key. `effort` is allowed only for claude and codex, from the same sets
    `--effort` accepts.
  - `allow`: a non-empty list of `{model, efforts?, note?}`. `efforts` is for
    claude and codex only.
  - `on_unknown`: `warn` or `deny`. It overrides `usage_gate.on_unknown` for
    this entry only.
  - `note`: a free text of at most 200 characters on one line, as is each
    allow `note`.
- Model strings follow `validate_model_name`. Each `models` selection must
  satisfy the entry's own `allow` list. Two entries of one role with the same
  `agent` and the same written `backend` are refused. Unknown keys at any level
  and duplicate JSON keys are refused. Every error names the file, the JSON
  path and the rule.

### Decision 4: The decision engine

`scripts/lib/agent_routing.py` is shipped beside `scripts/nogg` and loaded
like `session_backend`. It is a pure module: it takes the validated entries,
the role key, the optional tier, the skip set and callables (probes) for each
fact. It evaluates entries in file order. For each entry, the first failing
check gives the skip reason:

1. `operator-skip`: the agent is in `--skip-agent`.
2. `tier`: the entry's `tiers` excludes the launch tier, or the entry has
   `tiers` but the launch has none (detail `no tier given`).
3. `binary-missing`: the agent executable is not on `PATH`.
4. `authority`: the role and agent need authority the launch flags do not
   give, such as Codex or Antigravity planning without `--profile` or
   `--full-access`.
5. `backend-unavailable`: the backend's read-only preflight refuses. An
   explicit `--backend` replaces the entry's backend.
6. `model-not-allowed`: the resolved model and effort (Decision 6) fall
   outside the entry's `allow`, or the entry has an `allow` list and the model
   is unknown because it is the runtime default.
7. `usage-denied` or `usage-unknown`: the usage gate refuses, using the
   entry's `on_unknown` when set. Excluded roles and a disabled gate never
   skip.

The first entry that passes every check is chosen, and only its admission
reserves headroom. A denied entry's evaluation never writes the reservation
ledger. These are fatal and stop routing, not skips: a malformed routing file,
`usage_gate`, `tier_overrides` or model-selection table; an unreadable profile
or launch spec; a missing Bead or an unmet dependency; an invalid flag
combination. They are defects to fix, and skipping past them would hide a
broken install.

When every entry is skipped, the launch refuses and lists each entry with its
reason. It exits 75 when at least one entry was skipped only by
`usage-denied`, naming the earliest retry time among those entries, and exits
1 otherwise. Routing decides only before side effects. A start that fails
afterwards follows the existing failed-start path and is never retried on
another entry.

*Why this order:* cheap, local and deterministic checks come first. The usage
gate stays last, as today, because it is the only step that reserves.

### Decision 5: Routed, pinned, off-list and unrouted launches

- **Routed.** The role has a list and `--agent` is absent: the engine decides.
  `--model` and `--effort` are refused, because model names belong to one
  agent; the remedy is to pass `--agent`. `--resume` is refused, because a
  resume must keep its recorded agent; the remedy is to pass that `--agent`.
  `--skip-agent <agent>` is repeatable and allowed only here.
- **Pinned.** `--agent A` is given and the role lists `A`. The first entry for
  `A` applies, or the first with the explicit `--backend` when one is given.
  The entry supplies its backend (unless `--backend` is given), `models`,
  `allow` and `on_unknown`. There is no fall-through: a refusal is the
  launch's refusal, so a usage denial exits 75 as today. An explicit `--model`
  or `--effort` must satisfy the entry's `allow`, or the launch refuses. An
  exact resume keeps its recorded selection and never re-resolves entry
  `models`.
- **Off-list.** `--agent A` is given and the role's list has no `A`: the
  launch behaves exactly as today and records `routing.mode: off-list` with a
  NOTE.
- **Unrouted.** No routing file, or no list for the role: behavior, record
  and listing stay byte-for-byte as today, with no `routing` key.

*Why pin instead of ignoring routing on `--agent`:* the Product Owner's Sol
restriction must hold when the orchestrator explicitly picks Codex for an
extremely hard task. Pinning keeps the constraint without forcing every
launch through fall-through.

### Decision 6: Tier, model and effort per entry

With `--tier T`, a candidate resolves as follows:

- Model: explicit `--model` (pinned only), then entry `models[T].model`, then
  the table model (claude, codex, antigravity), then the profile `model`, then
  the runtime default.
- Effort, for claude and codex: explicit `--effort` (pinned only), then entry
  `models[T].effort`, then `tier_overrides`, then the table, then the profile,
  then the runtime default.
- A model or effort that comes from an entry is recorded with source `route`.
  So is `selection_tier_effort_source`. Pi and Antigravity take no effort.

A table-less agent (Pi) accepts `--tier` on a routed or pinned launch. The
tier is recorded as `selection_tier` for attribution with
`selection_tier_effort` null. The model comes from the entry, or from Pi's
profile or runtime default. A direct `--agent pi --tier` with no routing entry
still refuses, and its remedy now also names routing. Without `--tier`,
entries resolve exactly as a tier-less launch does today, and entries with
`tiers` are skipped.

Routing never changes the classified tier. Quota moves the launch to the next
entry at the same tier, which is the existing "another agent's entry for the
same tier" rule made mechanical. An entry's `models` map is explicit user
configuration, recorded as `route`, so it is never a silent downgrade.

### Decision 7: Visibility

The session record gains `routing`:
`{mode, file, role, chosen: {index, agent, backend}, skipped: [{index, agent,
backend, reason, detail}], skip_agents}`. Details pass through the existing
redactor and never contain a credential. Launch prints one line, for example
`routing=lead#2 codex/herdr; skipped #1 pi/herdr: binary-missing (pi not on
PATH)`. `session list` appends `route=#<n>` to the MODEL cell, then
`skipped=#<i>:<reason>,…` when higher entries were skipped. `session launch`
still performs no Beads mutation, so the orchestrator copies the `routing=`
line into the Bead note next to its tier reason.

### Decision 8: `nogg route`, `route check` and diagnostics

- `nogg route check` validates the file. It prints `agent routing <path>:
  absent (no routing)` or `… is valid (N roles, M entries)`, and exits 1 with
  every error on an invalid file.
- `nogg route` with no `--role` prints each role's entries with their
  effective per-tier model and effort, like `models`.
- `nogg route --role R [--bead B] [--tier T] [--skip-agent A]… [--agent A]
  [--backend B] [--profile P | --full-access] [--json]` runs the engine
  read-only. It writes no record, log, worktree or reservation. Usage is
  checked with `observe` plus a new read-only "would admit" check over the
  current reservations. Exit codes match the launch (0, 75, 1). The JSON gives
  the chosen entry, every skip with its reason and detail, and the resolved
  model, effort and sources. The output says it is a preview: another launch
  can take the headroom first, and only the launch decides.
- `validate` and `doctor` print a FAIL for an invalid file, as with
  `loops_file`, because every routed launch would refuse. They print a NOTE
  for an entry whose agent CLI is absent on this host, for a herdr entry when
  herdr is missing or the agent is not herdr-gated, and for an eligible tier
  whose table model falls outside the entry's `allow` (that tier skips the
  entry).
- `nogg models --agent A --tier T` adds a cross-reference line when a routing
  entry overrides that agent and tier, and the lookup JSON gains `routes`.
  `nogg usage` is unchanged: it stays the raw window view, and `route` is the
  effective-choice view.

### Decision 9: Generic shipped guidance

The PO-specific Codex sentences are removed from the orchestrator prompt, the
`/orchestrate` command, `docs/operating-model.md`, `docs/model-selection.md`
and `docs/using-with-codex.md`. The new tool-neutral procedure:

1. Classify the tier with a one-line reason (unchanged).
2. Optionally preview with `nogg route --role R --bead B --tier T`.
3. Launch with `--tier T` and no `--agent`.
4. Copy the tier reason and the `routing=` line into the Bead note.
5. Pass `--agent` only on Product Owner instruction, for an exact resume, or
   to use an allow-listed alternative model whose `note` condition holds. In
   that case pass `--agent A --tier T --model M --effort E` and record why.
6. A relaunch after a provider runtime limit keeps the tier and adds
   `--skip-agent <agent>`. A relaunch after a failed or stalled attempt
   escalates one tier (unchanged).
7. Never edit the routing file on its own initiative. On an explicit Product
   Owner instruction, change a tracked file through a `routine` Bead, or edit
   a host-local file directly and then run `nogg route check`.

`docs/model-selection.md` keeps the table and its values but describes them
neutrally. A regression check in `scripts/runtime-guidance-docs.test.sh` fails
if any shipped prompt, command or `docs/nogging/` source page contains "Product
Owner's Codex cost policy" or prescribes a fixed Codex model. It replaces the
current requirement that the Luna and Sol spellings appear.
`scheduled-loops` TASK-SCL-008 edits the same two prompt files: the
implementing task rebases onto `develop` and edits every shipped orchestrator
entry point present there.

### Decision 10: This repository's own routing

This lands as a separate `routine` task after the feature, without changing
any shipped file. The file is host-local and untracked (Product Owner
decision 1). This repository's tracked `.nogging/config.json` sets
`agent_routing_file: ".nogging/state/agent-routing.json"`, which is gitignored
and resolves under the main checkout, like `loops_file`. Only that one key is
committed; the routing content is never committed or published. Content
(Product Owner decisions 2-4):

- `lead` and `specialist` share the same order (decision 4):
  1. Pi on herdr, using Pi's own GLM default.
  2. Codex on herdr with `on_unknown: "deny"`: "when it has capacity" means
     usage is known and fits, and unknown usage skips to the next entry
     (decision 3). `models.complex` = `gpt-6-luna`/`medium` (decision 2), and
     `allow` = Luna at any effort, plus Sol at `low` with the note "extremely
     hard tasks only".
  3. Claude on herdr.
- `planning`: Claude only, backend from config.

The Lead commits the key, then writes the host-local file at the path the key
resolves to in the main checkout. That needs a `--full-access` Lead. If the
session cannot write the main checkout's `.nogging/state/`, it records a
blocking discovery and hands the write to the Orchestration Agent, which
writes the content above on this explicit Product Owner instruction and runs
`nogg route check` (see the orchestrator tier requirement). The task also
updates the `lead-agent-routing` and `codex-model-policy` Beads memories to
point at the file, so memory and configuration cannot disagree.

### Decision 11: Packaging and migration

`bin/lib/manifest.js` ships `scripts/lib/agent_routing.py` and the package
files list carries it. `templates/nogging-config.json` gains
`"agent_routing_file": ".nogging/agent-routing.json"`. An existing install
lacks the key and reads the same default. Without the file, launches, records
and `session list` are byte-for-byte unchanged, and packed init and update
tests prove it. `CHANGELOG.md` `[Unreleased]` gets an upgrade note: shipped
guidance no longer prescribes Codex models, plus a routing file that
reproduces the former wording for users who relied on it.

### Decision 12: Lanes and integration

Branches are `<type>/configurable-agent-routing`. Lanes: feat/ for TASK-RTG-001
to TASK-RTG-004 in sequence, docs/ for TASK-RTG-005, test/ for TASK-RTG-006 and
then TASK-RTG-008, chore/ for TASK-RTG-007. Before allocating a dependent
worktree, verify that every prerequisite execution commit is integrated into
`develop`; Bead closure alone is not enough. There is no Beads edge into
another change. File overlaps with `scheduled-loops` and `branded-docs-site`
are resolved by rebasing onto `develop`, never by waiting on their Beads.

## Risks / Trade-offs

- **Preview and launch can disagree.** A concurrent launch can take the
  headroom between them. Mitigation: `route` labels itself a preview, and the
  launch decision is recorded.
- **Routing can hide which agent ran.** Mitigation: the record, the launch
  line, `session list` and the Bead note all name the chosen entry and the
  skips.
- **Pi usage is unknown.** Under `warn` it is admitted every time with a
  WARN. A user who needs known headroom sets `on_unknown: "deny"` on that
  entry. A Z.ai limit hit at runtime surfaces as a `limit` session state, and
  the orchestrator relaunches with `--skip-agent pi` at the same tier.
- **A weaker model for a hard tier.** `models` lets a user map `complex` to a
  cheaper model. That is the user's explicit choice, recorded as `route`;
  Nogging never makes it silently.
- **A herdr server that is down passes preflight.** It then fails at start on
  the normal failed-start path, with no re-route after side effects.
- **Hosts with different CLIs.** One tracked file can list agents a host
  lacks. They are skipped with `binary-missing`, and `doctor` prints a NOTE.

## Migration Plan

No data migration. Install the release, optionally add a routing file, and run
`nogg route check`. Rollback means deleting the file (or the key) and
launches behave as before. Records carrying a `routing` block stay readable by
older listings, which ignore unknown keys.

## Product Owner decisions

The Product Owner approved the plan on 2026-10-27 and answered the five open
planning questions:

1. **Location.** This repository's routing file is host-local and untracked:
   `agent_routing_file` points to `.nogging/state/agent-routing.json`, like
   `loops_file`. The tracked default `.nogging/agent-routing.json` stays the
   shipped default for every other repository (Decision 10).
2. **Codex `complex` effort.** Codex `complex` runs on `gpt-6-luna` at
   `medium` through the entry's `models`.
3. **Codex "when it has capacity".** It means usage is known and fits. The
   Codex entry sets `on_unknown: "deny"`, so unknown usage skips to the next
   entry.
4. **Specialists.** Out-of-process specialists follow the same order as Leads.
   The `specialist` list repeats the `lead` list.
5. **Shipped table.** The shipped Codex `complex` default (`gpt-6.1-sol` at
   `low`) stays unchanged. This change does not touch
   `templates/model-selection.json` or `.nogging/model-selection.json`.
