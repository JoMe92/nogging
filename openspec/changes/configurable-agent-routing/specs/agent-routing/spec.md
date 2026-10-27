## ADDED Requirements

### Requirement: Agent routing is defined in one versioned, user-owned file

Nogging SHALL read agent routing from one JSON file, by default
`.nogging/agent-routing.json`, relocatable through the repository-relative
config key `agent_routing_file`, and resolved against the repository's main
checkout so every linked worktree reads the same file. The file SHALL carry
`schema_version: 1` and a `roles` object whose keys are `lead`, `specialist`
and `planning`, each an ordered non-empty list of entries. An entry SHALL have
an `agent` (`claude`, `codex`, `pi` or `antigravity`, with `agy` normalized to
`antigravity`) and MAY have a `backend` (`tmux` or `herdr`), `tiers` (a
non-empty subset of the model-selection tiers), `models` (keyed by tier, each
`{model, effort}` with at least one key, where `effort` is allowed only for
Claude and Codex from the values `--effort` accepts), `allow` (a non-empty
list of `{model, efforts, note}` where `efforts` is optional and allowed only
for Claude and Codex), `on_unknown` (`warn` or `deny`) and `note` (one line of
at most 200 characters, as is every allow `note`). Every `models` selection
SHALL satisfy its entry's own `allow` list. An `orchestrator` role key, an
empty list, two entries of one role with the same agent and written backend,
an unknown key at any level and a duplicate JSON key SHALL be refused naming
the file, the JSON path and the rule. A missing file SHALL mean no routing.
The installer SHALL NOT write the file and `update` SHALL NOT change it.
Nothing Nogging ships SHALL contain a routing preference.

#### Scenario: A valid file loads

- **WHEN** `.nogging/agent-routing.json` lists three `lead` entries and one `planning` entry, all well formed
- **THEN** the lists load in file order and no other file changes

#### Scenario: A missing file means no routing

- **WHEN** no routing file exists at the configured path
- **THEN** every launch resolves its agent exactly as before this capability existed

#### Scenario: A relocated file is read from the main checkout

- **WHEN** `agent_routing_file` is `.nogging/state/agent-routing.json` and a launch runs from a linked worktree
- **THEN** the file under the main checkout's `.nogging/state/` is read

#### Scenario: Malformed entries are refused by name

- **WHEN** an entry sets `effort` for Pi, lists an `orchestrator` role, or has a `models` selection its own `allow` list excludes
- **THEN** loading fails naming the file, the JSON path and the rule

### Requirement: Routing validation is reported by route check, validate and doctor

`scripts/nogg route check` SHALL validate the routing file, print whether it is
absent or valid with its role and entry counts, and exit non-zero naming every
error on an invalid file. `validate` and `doctor` SHALL report an invalid file
as a FAIL. `doctor` SHALL print a NOTE, never a failure, for an entry whose
agent executable is not on `PATH`, for a `herdr` entry while herdr is missing
or the agent is not herdr-gated, and for an eligible tier whose table model
and effort fall outside the entry's `allow` list.

#### Scenario: An invalid file fails validation

- **WHEN** the routing file contains an unknown key
- **THEN** `route check` exits non-zero naming the key, and `validate` and `doctor` print a FAIL

#### Scenario: A missing CLI is a note

- **WHEN** the file lists Pi first and `pi` is not on `PATH`
- **THEN** `doctor` prints a NOTE that the entry is skipped at launch and its exit code is unchanged

### Requirement: A launch without an agent follows the role's routing list

When the launch role has a routing list and `--agent` is absent,
`scripts/nogg session launch` SHALL evaluate the entries in file order before
any worktree, trust, settings, record, log, backend or reservation side
effect, and SHALL launch the first entry that passes every check. An entry
SHALL be skipped, in this order of checks, with reason `operator-skip` (its
agent was passed to `--skip-agent`), `tier` (its `tiers` excludes the launch
tier, or it has `tiers` and the launch has no tier), `binary-missing`,
`authority` (the role and agent need authority the launch flags do not give),
`backend-unavailable` (the backend's read-only preflight refuses; an explicit
`--backend` replaces the entry backend), `model-not-allowed` (the resolved
selection falls outside `allow`, or `allow` is set and the model is the
unknown runtime default), or `usage-denied` / `usage-unknown` (the usage gate
refuses under the entry's `on_unknown` when set, else `usage_gate.on_unknown`).
Only the chosen entry's admission SHALL reserve usage headroom. A malformed
routing file, usage gate, tier override block or model-selection table, an
unreadable profile, a missing Bead or an unmet dependency SHALL refuse the
launch instead of skipping. When every entry is skipped the launch SHALL refuse
listing each entry and reason, and SHALL exit 75 naming the earliest retry
time when at least one entry was skipped only for `usage-denied`, and 1
otherwise. Routing SHALL NOT retry another entry after side effects began.
`--model` and `--effort` without `--agent` SHALL be refused because model
names are agent-specific, and `--resume` without `--agent` SHALL be refused.

#### Scenario: A missing first agent falls through

- **WHEN** the `lead` list is Pi on herdr, Codex on herdr, Claude on herdr, `pi` is not on `PATH`, and Codex usage fits
- **THEN** a Codex session starts on herdr and the record lists entry 1 as skipped with `binary-missing`

#### Scenario: Quota moves to the next agent at the same tier

- **WHEN** a `--tier complex` routed launch finds Codex over the usage cap and Claude admitted
- **THEN** Claude starts with its `complex` selection, and only Claude's reservation is written

#### Scenario: Unknown usage can require known headroom

- **WHEN** the Codex entry sets `on_unknown: "deny"` and Codex usage is unknown
- **THEN** the entry is skipped with `usage-unknown` and the next entry is evaluated

#### Scenario: Every entry skipped for quota waits

- **WHEN** every entry is skipped and at least one only for `usage-denied`
- **THEN** the launch exits 75 naming the earliest limiting reset and creates no session

#### Scenario: A defect is not skipped

- **WHEN** the first entry's agent has an unreadable launch profile
- **THEN** the launch refuses naming the profile instead of trying the next entry

#### Scenario: Agent-specific flags need an agent

- **WHEN** a routed launch passes `--model gpt-6-luna` without `--agent`
- **THEN** the launch refuses with the remedy to pass `--agent`

### Requirement: An explicit agent pins its entry or bypasses routing

When `--agent A` is given and the role's list has an entry for `A`, the launch
SHALL use the first such entry, or the first with the explicit `--backend` when
one is given. It SHALL apply that entry's backend unless `--backend` is given,
and its `models`, `allow` and `on_unknown`, and SHALL NOT fall through to
another entry. An explicit `--model` or `--effort` outside the entry's `allow`
list SHALL refuse. When the list has no entry for `A`, the launch SHALL behave
exactly as without routing and SHALL record the mode `off-list` with a NOTE.
`--skip-agent` SHALL be accepted only on a routed launch. When the role has no
list, the launch, its record and `session list` SHALL be unchanged and the
record SHALL carry no `routing` key.

#### Scenario: A pinned launch keeps the allow-list

- **WHEN** `--agent codex --tier complex --model gpt-6.1-sol --effort high` is launched and the Codex entry allows Sol only at `low`
- **THEN** the launch refuses naming the allow-list and creates no session

#### Scenario: A pinned allowed alternative launches

- **WHEN** `--agent codex --tier complex --model gpt-6.1-sol --effort low` is launched under the same entry
- **THEN** Codex starts with `gpt-6.1-sol` at `low`, recorded with mode `pinned`

#### Scenario: A pinned denial does not fall through

- **WHEN** `--agent codex` is launched and Codex is over the usage cap
- **THEN** the launch exits 75 and no other agent starts

#### Scenario: An unlisted agent launches as before

- **WHEN** `--agent antigravity` is launched and the role's list has no Antigravity entry
- **THEN** the launch behaves as without routing and records mode `off-list`

### Requirement: Route entries supply tier model and effort with recorded provenance

For a routed or pinned candidate and `--tier T`, the model SHALL resolve from
an explicit `--model` (pinned only), then the entry's `models[T].model`, then
the table, then the profile, then the runtime default. For Claude and Codex the
effort SHALL resolve from an explicit `--effort` (pinned only), then the
entry's `models[T].effort`, then `tier_overrides`, then the table, then the
profile, then the runtime default. A value from an entry SHALL be recorded with
source `route`. A routed or pinned launch of an agent without table entries,
such as Pi, SHALL accept `--tier`, record it as `selection_tier` with a null
`selection_tier_effort`, and take the model from the entry, the profile or the
runtime default. Routing SHALL keep the classified tier on every candidate and
SHALL NOT lower it.

#### Scenario: An entry replaces the table model for one tier

- **WHEN** the Codex entry maps `complex` to `gpt-6-luna` at `medium` and a routed `--tier complex` launch chooses it
- **THEN** Codex receives `gpt-6-luna` and reasoning effort `medium`, both recorded with source `route`, and `selection_tier` stays `complex`

#### Scenario: Pi records the tier

- **WHEN** a routed `--tier standard` launch chooses the Pi entry, which has no `models`
- **THEN** Pi starts with its own default model, and the record stores `selection_tier` `standard` with model source `runtime-default`

### Requirement: The routing decision is visible

A routed, pinned or off-list launch SHALL record a `routing` block with the
mode, the file, the role key, the chosen entry's index, agent and backend, and
every skipped entry with its index, agent, backend, reason and redacted
detail. Launch SHALL print one `routing=` line naming the chosen entry and
every skip. `session list` SHALL show `route=#<n>` and, when higher entries
were skipped, each skipped index with its reason. `session launch` SHALL still
perform no Beads mutation.

#### Scenario: Skips are listed

- **WHEN** a routed launch skipped entry 1 for `binary-missing` and chose entry 2
- **THEN** `session list` shows `route=#2` and `skipped=#1:binary-missing` for the session

### Requirement: Operators can preview a routing decision read-only

`scripts/nogg route` without `--role` SHALL print every role's entries with
their effective per-tier model and effort. `scripts/nogg route --role R` with
optional `--bead`, `--tier`, `--skip-agent`, `--agent`, `--backend`,
`--profile` or `--full-access`, and `--json`, SHALL run the same decision as
the launch without any record, log, worktree, trust, settings or reservation
write. It SHALL check usage with a read-only admission over the current
reservations, use the launch's exit codes, and state that the launch decides.
`nogg models --agent A --tier T` SHALL name any routing entry that overrides
that agent and tier.

#### Scenario: Preview writes nothing

- **WHEN** `nogg route --role lead --tier standard --json` runs with Codex admitted
- **THEN** it prints the chosen entry, skips and resolved selection, and the reservation ledger and session directory are unchanged

### Requirement: Shipped guidance carries no project-specific routing preference

The shipped orchestrator launch prompt, the `/orchestrate` command and every
shipped docs page SHALL NOT prescribe a fixed agent order or a fixed Codex
model. They SHALL tell the orchestrator to follow the project's routing:
launch without `--agent`, copy the tier reason and the `routing=` line into
the Bead note, pass `--agent` only on Product Owner instruction, for an exact
resume, or for an allow-listed alternative whose `note` condition holds, keep
the tier and add `--skip-agent` on a relaunch after a provider runtime limit,
and change the routing file only on an explicit Product Owner instruction. A
repository test SHALL fail when shipped prompts, commands or shipped docs
contain the phrase "Product Owner's Codex cost policy".

#### Scenario: Shipped files are generic

- **WHEN** the package payload is inspected
- **THEN** no shipped prompt, command or doc names a fixed Codex model as the default to launch, and the routing procedure is stated
