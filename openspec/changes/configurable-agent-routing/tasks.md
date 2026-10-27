## 1. Routing file and validation (feat/)

- [ ] TASK-RTG-001 [standard] Routing file loader, validator and route check.
  Per design Decisions 1-3 and 8 and the agent-routing file and validation
  requirements: add scripts/lib/agent_routing.py (pure, loaded beside
  scripts/nogg like session_backend, shipped in bin/lib/manifest.js and the
  package files list) with the schema_version 1 loader. It refuses duplicate
  JSON keys, unknown keys, an orchestrator role, empty lists, duplicate
  agent/backend pairs and Pi/Antigravity effort. It validates models, allow
  and notes, checks models against the entry's own allow, normalizes agy and
  names file, JSON path and rule in every error. Add the
  `agent_routing_file` key (default `.nogging/agent-routing.json`, in
  templates/nogging-config.json) resolved against the main checkout, with a
  missing file meaning no routing. Add `nogg route check`, the doctor/validate
  FAIL for an invalid file and the doctor NOTEs (missing CLI, herdr missing or
  agent not gated, table model outside allow). Document the key and the file
  in docs/configuration.md, whose key coverage scripts/docs-site.test.sh
  checks. Check: new scripts/lib/agent_routing_test.py and
  scripts/agent-routing.test.sh, red first, covering every scenario of the
  file and validation requirements including linked-worktree resolution;
  docs-site, package-manifest and nogg suites; scripts/test. Branch feat/.

## 2. Decision engine (feat/)

- [ ] TASK-RTG-002 [standard] Pure routing decision engine with injected probes.
  Per design Decisions 4 and 6: in scripts/lib/agent_routing.py add the
  ordered evaluation over a role's entries. It takes an optional tier, a skip
  set and probe callables for binary, authority, backend preflight, selection
  resolution and usage evaluation. It returns the chosen entry or every skip
  with the reason codes operator-skip, tier, binary-missing, authority,
  backend-unavailable, model-not-allowed, usage-denied and usage-unknown, in
  that check order, plus redaction-ready detail. It resolves per-entry
  model and effort precedence with `route` provenance, the allow check
  (including an unknown runtime-default model under allow), per-entry
  on_unknown, table-less tier recording, fatal-versus-skip classification and
  the all-skipped outcome (75 with the earliest retry when any entry was only
  usage-denied, else 1). No I/O. Check: extend
  scripts/lib/agent_routing_test.py, red first, with every order, reason,
  precedence, allow, on_unknown, fatal and exit-classification case of the
  launch and selection requirements; scripts/test. Branch feat/ (after
  TASK-RTG-001).

## 3. Routed launch (feat/)

- [ ] TASK-RTG-003 [complex] Wire routing into session launch, records and session list.
  Per design Decisions 4-7 and the launch, pinning, selection and visibility
  requirements: in scripts/nogg `_session_launch`, build the real probes
  (require_agent_binary, planning_launch_authority, choose_launch_backend plus
  backend preflight, resolved_launch_pair and spec loading, resolve_launch_tier
  extended for route entries and table-less agents, usage_gate_admission with
  the entry's on_unknown). Evaluate them through the engine before any side
  effect, reserving only for the chosen entry and refusing fatal defects. Add
  the routed, pinned, off-list and unrouted modes, `--skip-agent`
  (repeatable, routed only), the refusal of `--model`/`--effort`/`--resume`
  without `--agent` on a routed launch, and allow enforcement for explicit
  flags on a pinned launch. Write the record's `routing` block, the `route`
  model/effort/selection_tier_effort sources and the printed `routing=` line.
  Add `route=#n` and `skipped=` plus `effort=<level> (route)` to the session
  list MODEL cell. Keep unrouted launches, records and listings byte-for-byte
  unchanged and perform no Beads mutation. Check: new
  scripts/session-routing.test.sh, red first, with stub agents, fake herdr and
  stub tmux, covering every scenario of the launch, pinning, selection and
  visibility requirements including reservation-ledger contents and no side
  effects on refusal; session-tier, session-tier-overrides,
  session-model-record, session-backend-select, packed-usage-gate and
  session.test.sh green; scripts/test. Branch feat/ (after TASK-RTG-002).

## 4. Preview and cross-references (feat/)

- [ ] TASK-RTG-004 [standard] nogg route preview, read-only admission and models cross-reference.
  Per design Decision 8 and the preview requirement: add a read-only "would
  admit" check to scripts/nogg_usage.py that evaluates observe() against the
  current reservations without writing the ledger. Add `nogg route` (no
  --role: every role's entries with the effective per-tier model and effort;
  with --role and optional --bead, --tier, --skip-agent, --agent, --backend,
  --profile or --full-access, and --json: the launch's decision through the
  same probes, with the launch's exit codes and a preview notice). It writes
  no record, log, worktree, trust, settings or reservation. Make
  `nogg models --agent A --tier T` print a cross-reference line for an
  overriding entry and add `routes` to the lookup JSON. Check: extend
  scripts/agent-routing.test.sh, red first, asserting text and JSON output,
  exit codes 0/75/1 and unchanged ledger and session directory;
  model-selection, model-selection-overrides and nogg_usage tests green;
  scripts/test. Branch feat/ (after TASK-RTG-003).

## 5. Generic guidance and docs (docs/)

- [ ] TASK-RTG-005 [standard] Remove the shipped Codex policy wording and document routing.
  Per design Decision 9 and the shipped-guidance and orchestrator tier
  requirements: rebase onto develop first, because TASK-SCL-008 edits the
  same prompt files. Then, in .nogging/launch-prompts/orchestrator.md,
  .claude/commands/orchestrate.md and every other shipped orchestrator entry
  point present on develop, replace the Product Owner's Codex cost policy
  with the generic routing procedure: launch without --agent, put the routing=
  line in the Bead note, the --agent exceptions, allow-list notes,
  --skip-agent after a runtime limit, and routing-file changes only on
  explicit instruction. Do the same in docs/operating-model.md,
  docs/model-selection.md (drop the policy section, keep the table values
  with neutral rationale, add route precedence and table-less tier
  recording) and docs/using-with-codex.md. Also update docs/configuration.md
  (full routing block), docs/commands.md (`route`, `--skip-agent`),
  docs/running-work-in-sessions.md, docs/using-with-pi.md (tiers under
  routing), the AGENTS.md Supervised sessions paragraph and CHANGELOG.md
  [Unreleased] with the upgrade note and an equivalent routing file example.
  In scripts/runtime-guidance-docs.test.sh, replace the required Luna/Sol
  spellings with required routing phrases and fail on "Product Owner's Codex
  cost policy" in any shipped prompt, command or doc. Check:
  runtime-guidance-docs, docs-site, commands, planning-docs and
  installation-docs suites; scripts/test. Branch docs/ (after TASK-RTG-004).

## 6. Packaging, migration and integration (test/)

- [ ] TASK-RTG-006 [standard] Packed install, update and legacy-launch regression coverage.
  Per design Decision 11: prove in the packed suites that init scaffolds
  `agent_routing_file` and writes no routing file. Prove that update keeps an
  existing config without the key and an existing routing file unchanged, and
  ships scripts/lib/agent_routing.py. Prove that an install without a routing
  file launches, records and lists byte-for-byte as before for Claude, Codex,
  Pi and Antigravity, and that a packed consumer with a routing file
  routes, pins and previews correctly. Check: extend
  scripts/packed-session-launch.test.sh, scripts/packed-model-selection.test.sh
  and scripts/cli.test.sh; one isolated full scripts/test with inherited
  NOGG_* cleared and bd absent. Branch test/ (after TASK-RTG-005).

## 7. This repository's routing (chore/)

- [ ] TASK-RTG-007 [routine] Set this repository's own host-local agent routing preference.
  Per design Decision 10 and the Product Owner decisions in design.md: in this
  repository's tracked .nogging/config.json set `agent_routing_file` to
  `.nogging/state/agent-routing.json` (host-local, gitignored) and commit only
  that key. Then write the host-local file at the main checkout path the key
  resolves to, never committing it. For lead and specialist, in the same
  order: Pi on herdr; then Codex on herdr with on_unknown deny,
  models.complex gpt-6-luna at medium, and allow Luna plus gpt-6.1-sol at low
  with note "extremely hard tasks only"; then Claude on herdr. For planning:
  Claude only. Change no shipped file and not the model-selection table. Run
  `nogg route check` and `nogg route --role lead --tier standard --json` and
  record both outputs as evidence. Update the Beads memories
  lead-agent-routing and codex-model-policy so they point at the file instead
  of restating the order. Needs a --full-access Lead. If the session cannot
  write the main checkout's .nogging/state/, record a blocking discovery and
  hand the file write to the Orchestration Agent. Check: route check passes;
  git status shows the routing file untracked and ignored; doctor prints no
  routing FAIL; scripts/test. Branch chore/ (after TASK-RTG-006).

## 8. Live acceptance (test/)

- [ ] TASK-RTG-008 [standard] Bounded live routing acceptance in a scratch consumer repository.
  Per design Decisions 1, 4 and 7: in a disposable packed scratch consumer
  with a private tmux socket and a scratch routing file, never the fleet
  socket, the canonical planning lock or the Orchestration Agent, run real
  routed launches on the installed CLIs. Cover: first entry chosen; a missing
  CLI or --skip-agent fall-through; a usage-denied entry via a low scratch
  cap_percent; a pinned allow-list refusal; an off-list launch; route preview
  agreement; session list route and skipped cells. Stop and clean up every
  session. Write docs/acceptance/<date>-configurable-agent-routing.md with
  versions and honest pass/fail/skipped results, and leave Signed-off-by
  empty. Report quota or missing CLIs as skipped, never as passed. Check:
  report committed unsigned; scripts/test. Branch test/ (after TASK-RTG-006).

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` means A
depends on B): 002<-001; 003<-002; 004<-003; 005<-004; 006<-005; 007<-006;
008<-006. TASK-RTG-007 and TASK-RTG-008 run in parallel after TASK-RTG-006.
There is no edge into another change. File overlaps with scheduled-loops
(TASK-SCL-008, the orchestrator prompt and command) and branded-docs-site
(sessions and configuration pages) are resolved by rebasing onto develop, as
design Decision 12 states.

Branches are `<type>/configurable-agent-routing` with these lanes: feat/ 001,
002, 003, 004 in sequence; docs/ 005; test/ 006 then 008; chore/ 007. A lane's
next task reuses its prefix only after the previous branch is integrated and
deleted. Before allocating a dependent worktree, verify that every
prerequisite execution commit is integrated into develop; Bead closure alone
is not enough.

## Execution contract

A task's first line is its Bead title. Its full slice is that line plus the
indented paragraph under it, the design Decisions it names, design Decision 1,
and the matching requirements in specs/. The Main Worker claims each task and
implements it only in its own allocated worktree on its lane branch. Write the
tier classification to the Bead note on every launch, including Pi launches.
Every suite is offline in scripts/test (no Dolt, bd, shared tmux or herdr
server, real agent CLI or network; stub binaries, fake herdr, injected usage).
Run the task's named checks; the full scripts/test runs in CI. Then commit
with a Conventional subject ending in the real Bead token, push the lane
branch and open the pull request against develop. Only then run bd close and
`scripts/nogg task-done`, and append the SHA and evidence to the Bead. A Codex
Lead needs --full-access or --profile trusted to reach the shared Dolt server.
Agents never hand-edit OpenSpec. Discoveries carry the discovery label and
prose. Prompts, fixtures and docs contain no email address, and the owner is
named only as Jonas or JoMe92. Nobody signs human acceptance.
