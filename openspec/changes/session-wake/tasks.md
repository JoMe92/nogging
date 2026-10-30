## 1. Signals (feat/)

- [ ] TASK-SWK-001 [standard] [~650 loc] One normalized lifecycle stream for Claude and Codex, `session signal`, and one evidence order for every agent.
  Per design Decisions 1, 2, 3 and 4 and the session-observability requirements on
  normalized events, Codex rollouts, the Lead signal and watch classification. Add
  pure scripts/lib/session_signals.py (event schema 2, field whitelist, excerpt
  rules, the `Notification` type map, the state mapping), loaded beside scripts/nogg
  like session_backend and shipped in bin/lib/manifest.js and the package files.
  `session emit` reads at most 64 KiB of stdin, tolerates junk and rotates the
  events file at 256 KiB. Wire `UserPromptSubmit` as `turn_start`, plus `StopFailure`
  and `SessionEnd`, and pass the `Notification` type through; do not wire
  `SubagentStop`. An `idle` from an event yields to a live `working` pane, which fixes
  Claude sessions reading `idle` during a later turn. Add `session signal
  blocked|done "<reason>"`, allowed in the restricted profile, printing whether
  dispatch is on and what to do next. Extend session_codex_delivery.py with a
  bounded last-turn reader for `task_complete` and aborts, using the existing thread
  resolution. Give classify_session one evidence order for every agent and keep the
  stale `needs_input` reconciliation. Signals stay events, not classified states, so
  every caller that tests `idle` is unchanged. `session watch` reports signals as
  their own events. Antigravity's Stop path is untouched. Document `session signal`
  and `session emit` in docs/commands.md in `nogg --help` order and update
  docs/running-work-in-sessions.md, docs/using-with-codex.md and CHANGELOG.md
  [Unreleased]. Check: new scripts/session-signals.test.sh, red first, with committed
  Claude hook payloads and a Codex rollout excerpt (no real path, email or secret);
  session-backend, session-codex-* and docs-site suites. Branch feat/.

- [ ] TASK-SWK-002 [standard] [~420 loc] Supervised Pi sessions report their lifecycle through a mandatory extension, and herdr status joins the evidence.
  Per design Decisions 1, 2 and 12 and the Pi lifecycle requirement. Add
  .pi/extensions/nogging-lifecycle.ts beside the guard, not under .pi/nogging/,
  because it must load in every supervised session. It is inert unless
  NOGG_SESSION_NAME is set, is plain erasable TypeScript with only Node built-ins and
  a process-global single-instance guard, and maps agent_start, agent_settled,
  ui_prompt_start, ui_prompt_end and session_shutdown onto `session emit` through a
  timeout-bounded, unref'd execFile of $NOGG_SESSION_ROOT/scripts/nogg. agent_end is
  never used as completion. Take the excerpt from the settled run's last assistant
  message. Report `turn_error` from `outcome: "error"`. Pass the extension explicitly
  from scripts/session-launch beside the guard, and treat a missing file as a warning
  because observability never blocks a launch. Add herdr agent_status to the evidence
  order with its documented meaning: `blocked` is needs_input, `done` is idle,
  `unknown` proves nothing. Pi's classification then works on tmux and herdr. Update
  docs/using-with-pi.md and the Pi tool note in AGENTS.md. Check: new
  scripts/pi-lifecycle.test.sh, red first, driving the extension with a fake pi and
  ctx under Node type stripping, with a skip-pass where Node cannot strip types:
  retry after agent_end, double load, inert without the variable, a stuck child that
  cannot delay shutdown; a watch test with a stub Pi on a private socket;
  pi-guard, session-backend-herdr, herdr-stub and docs-site suites. Branch feat/
  (after TASK-SWK-001).

- [ ] TASK-SWK-003 [complex] [security] [~780 loc] A Lead never stops silently: completion check, bounded stop guards, the Codex user-level hook, prompt rules and runtime capabilities.
  Per design Decisions 3, 5, 10 and 11 and the requirements on the stop guard, the
  Codex hook, the Lead signal and capabilities. Add pure completion_gaps() and `nogg
  session completion-check [--json]`, failing open. Add `session emit turn_end
  --guard` for Claude's Stop hook and the Codex hook, and agent_before_settle in the
  Pi extension, each with the bounds of Decision 5 and the fixed message, recording a
  continued stop as `guard_continue`. Add `nogg
  session-hooks {status,install,remove} --agent codex`: merge one constant user-level
  Stop entry, record trust through the app-server's config/value/write, read state
  back through hooks/list, inject the app-server call so tests need no real Codex, and
  never touch another entry. Add a doctor NOTE. Assert that no launch passes
  --dangerously-bypass-hook-trust. Add `nogg session capabilities`, derived from what
  launch resolves. Refuse a sandboxed `session launch` before side effects with a clear
  message instead of a raw Errno 30. Edit AGENTS.md (hard rule 6 and the stale Codex
  subagent note only if the capability table proves it stale),
  .nogging/launch-prompts/autonomous.md (signal instead of waiting for CI, a refused
  step means signal blocked at once) and docs/security-model.md (why trust is
  user-level and the bypass is refused). The review follows the execution contract's
  [security] rule. Check: new
  scripts/session-guard.test.sh and scripts/session-hooks.test.sh, red first, with
  scratch HOME and CODEX_HOME and a stub app-server: every stop-guard scenario on all
  three runtimes, a foreign hook preserved, modified and missing states, fail-open on
  a raising check, a launch refusal with no side effects; agents-boundary,
  commands, session-launch and docs-site suites. Branch feat/ (after TASK-SWK-002).

## 2. Dispatcher (feat/)

- [x] TASK-SWK-004 [complex] [~900 loc] The dispatcher: a level-triggered pass with deterministic follow-ups and no model.
  Per design Decisions 6, 7 and 13 and the session-wake requirements on reconciling,
  opt-in, routine transitions and nudges. Add pure scripts/lib/session_dispatch.py with
  decide(facts, memory, policy, now) and dedupe keys, shipped in the manifest. Add `nogg
  session dispatch [--once] [--dry-run] [--json]` with the main-checkout rule, the
  supervised-session refusal, the non-blocking dispatch lock and the
  .nogging/state/dispatch/ files. Gather facts from classify_session, completion_gaps,
  _sweep_state and _observe_checks, the latter extended with mergeable, additions and
  deletions and throttled to 120 s per session; `bd` reads are cached 300 s and a failed
  read is `unknown`. Implement the nudges with their budgets, CI and conflict tracking,
  the stall ladder, the crash finding, and `retire_merged`. Factor the non-blocking
  resume_step out of session_resume_when_ready without changing that command. Queue
  items here, without delivery: `session dispatch` prints them. Add the
  `session_dispatch` and `orchestrator_context` config blocks with unknown-key refusal
  in validate and doctor, to templates/nogging-config.json and docs/configuration.md,
  whose key coverage the docs-site suite checks. Add the commands to docs/commands.md.
  Check: new scripts/session-dispatch.test.sh, red first: every row of the Decision 7
  table as a pure decide() case with an injected clock, and an integration case with
  stub agents on a private socket, a stub gh and a stub bd covering a missed hook, a
  replayed pass, unknown evidence, a disabled config and `--dry-run`;
  session-sweep, session-resume, nogg and docs-site suites. Branch feat/ (after
  TASK-SWK-003).

- [ ] TASK-SWK-005 [complex] [security] [~620 loc] One coalesced digest: the wake queue, delivery to the orchestrator, the inbox and the wake protocol.
  Per design Decisions 8, 9, 11 and 12 and the session-wake requirements on the digest,
  delivery and state, and the orchestration-agent requirements on the digest, watchers
  and kickoffs. Add level-triggered queue evaluation, urgent and normal quiet periods,
  max_hold, min_gap, max_wakes_per_hour, remind_after and the usage hold through the
  existing observe and gate_config. Render the digest under 1.5 KiB with data labelling
  and the overflow pointer, escaping any header-like text in an item. Deliver through
  the idle-only send helper from TASK-SCL-005, reusing it, not duplicating it; a failed
  delivery keeps the items. Add read-only `nogg session inbox [--json]`, and the audit
  log with rotation. Add the wake protocol, the no-watcher rule and the capability rule
  to .nogging/launch-prompts/orchestrator.md and .claude/commands/orchestrate.md, keeping
  it generic and rebasing onto what scheduled-loops and dual-runtime-orchestrator landed.
  The review follows the execution contract's [security] rule. Check: new
  scripts/session-wake-digest.test.sh, red first, with an injected clock and a stub
  orchestrator that is idle, working, holding input or absent: a condition clearing
  before delivery, three items in one message, the max_hold bound, the rate ceiling,
  urgent bypass, reminders, a restart with queued items, secrets and an injected header
  in an excerpt; orchestrator and commands suites and docs-site. Branch feat/ (after
  TASK-SWK-004 and TASK-SCL-005).

- [ ] TASK-SWK-009 [complex] [security] [~520 loc] A user pause: `nogg pause`, `resume`, a held queue, skipped loops and one digest on resume.
  Per design Decisions 8 and 16 and the session-wake requirements on pause, resume and
  its visibility. Add pure scripts/lib/session_pause.py (parse of `--until` and `--days`
  with the 60-day bound, kept-loop validation, atomic read and write of
  .nogging/state/pause.json, a malformed file meaning not paused, status rendering) with
  an injected clock, shipped in bin/lib/manifest.js and the package files. Add `nogg
  pause [--until|--days] [--keep-loop <name> ...]`, `pause --status [--json]` and `nogg
  resume`, refused in every supervised session except the Orchestration Agent like
  `loop run-now`, with `--status` read-only everywhere. Gate the dispatcher and the
  delivery from TASK-SWK-005 on the pause: no digest, nudge, `limit` resume or compaction,
  the queue and retirement continue, and each item that appeared or cleared is appended to
  the audit log. Make `nogg loop tick` skip loops outside `keep_loops` as `paused-global`
  without writing any loop file or state, and end the pause at its time in both `loop
  tick` and `session dispatch --once`, queueing one `resumed` item only when something
  happened, delivered with the held items as one digest. Show the pause in `doctor` as a
  NOTE, in `session list`, `loop list` and `session inbox`. Add the commands to
  docs/commands.md in `nogg --help` order, a short pause entry to docs/configuration.md
  and CHANGELOG.md [Unreleased]. The review follows the execution contract's [security]
  rule. Check: new scripts/session-pause.test.sh, red first, with an injected clock:
  every `--until` and `--days` form, an invalid end, an unknown kept loop, replacement,
  a corrupt file, a Lead refused and `--status` allowed, a paused tick skipping loops,
  a kept loop running, an individually paused loop staying paused, a pause ending at its
  time with and without events, and one digest on resume; loop-tick, session-wake-digest,
  commands and docs-site suites. Branch feat/ (after TASK-SWK-005).

- [ ] TASK-SWK-010 [complex] [security] [~480 loc] Quiet hours, the keep-warm rule and the one compaction before the cache lapses.
  Per design Decisions 8, 9 and 15 and the session-wake requirements on quiet hours and
  the warm cache, and the orchestration-agent requirement on a keep-warm. Add pure
  scripts/lib/session_warm.py (quiet-hours parsing and the wall-clock test, including a
  window across midnight, and warm_plan(facts, policy, now) returning keep-warm,
  compact or nothing from the orchestrator's idle age, activity, pause, quiet hours, cache
  lifetime and context size), shipped in the manifest and package files. Gate the digest
  delivery of TASK-SWK-005 on quiet hours for every item, urgent included, and keep the
  queue level-triggered. Send the fixed keep-warm line and the fixed `/compact`
  instruction through the verified idle-only helper of TASK-SWK-005 only to a Claude
  orchestrator, never counting a keep-warm against `min_gap` or the rate ceiling, holding
  it under the usage hold, and reading the context size from a bounded tail of the
  transcript the `Stop` input names. Add `wake.keep_warm`, `wake.keep_warm_after` and
  `wake.quiet_hours` to the config block with unknown-key and malformed-window refusal in
  validate and doctor, to templates/nogging-config.json and docs/configuration.md. Add the
  keep-warm answer rule and the pause-on-instruction rule to
  .nogging/launch-prompts/orchestrator.md and .claude/commands/orchestrate.md, generic and
  rebased onto what landed there. Add a doctor line for keep-warm, quiet hours and the next
  compaction. The review follows the execution contract's [security] rule. Check: new
  scripts/session-warm.test.sh, red first, with an injected clock and a stub orchestrator
  that is idle, working or holding input: every row of the Decision 15 table as a pure
  warm_plan() case, the interval reset by a real wake, a lapsed cache, an unreadable size,
  keep_warm false, a pause forcing the compaction branch, a window delivering one digest
  after it ends, an urgent item held inside it and a malformed window refused;
  session-wake-digest, orchestrator, commands and docs-site suites. Branch feat/ (after
  TASK-SWK-009).

- [ ] TASK-SWK-006 [standard] [~680 loc] Scheduler wiring, dispatch on by default, doctor health, the orchestrator context budget and the guide, including how to pause.
  Per design Decisions 7, 9, 12, 13, 15 and 16, Product Owner decision 6 and the
  requirements on the scheduler, diagnostics, the context budget, dispatch on by default
  and the installer. Make dispatch on by default: set `enabled: true` in
  templates/nogging-config.json and read a missing `session_dispatch` block or `enabled`
  key as on through the one `policy_from` in scripts/lib/session_dispatch.py, replacing
  every `enabled is True` test in scripts/nogg (`session signal`, `session dispatch`, the
  tick, `doctor`) with it; only an explicit `false` is off; `retire_merged` stays `false`.
  Make a pass with no orchestrator session or no timer exit 0 quietly: nudges and CI
  tracking continue, the digest has no target and is held without an error or a repeated
  log line, and `doctor` prints one NOTE each for the missing orchestrator and the
  missing timer, with the fix and the `session_dispatch.enabled: false` switch, and none
  when disabled or paused. `update` keeps an existing `enabled` value, including `false`,
  and prints one line when the key is missing saying dispatch is on and how to switch it
  off. Add a CHANGELOG line under Changed that dispatch is on by default. Call the
  dispatch pass first in `nogg loop tick` under its own lock and exception boundary,
  after the pause end check of TASK-SWK-009. Add doctor reporting: disabled or stale
  dispatcher, queue depth, oldest item, exhausted budgets, Codex hook state, and whether
  the orchestrator's watchers are still needed. Write the orchestrator_context values into its effective settings `env`.
  Add the new consumer-copied docs/session-wake.md under Guides in docs/_config.yml and to
  manifest docs and package files: a first section, "Dispatch is on by default", saying
  plainly that it is on, what it does and does not do (fixed nudges, CI tracking, a held
  digest, no model, no merge, no retirement unless `retire_merged`), what changes with no
  orchestrator or timer, and how to switch it off (`session_dispatch.enabled: false`) or
  pause it (`nogg pause`); then concepts, the evidence per runtime, the follow-up table,
  the digest format, tuning, disabling it, the token model and troubleshooting, and a
  section for the user on pausing: what the orchestrator costs while waiting, when
  keep-warm pays and when pausing does, the break of about a day that pays, the commands
  `pause`, `resume` and `pause --status` with an example each, quiet hours, and the config
  keys. Add sections to operating-model, architecture and failure-recovery, and a pointer
  from README.md to the guide. Check: new scripts/session-wake-integration.test.sh, red
  first, with a stub orchestrator and stub agents through a full Lead life cycle from
  kickoff to merged, using an injected clock and a stub gh, then the same life cycle
  across a pause and a quiet-hours window; scripts/cli.test.sh and the packed suites prove
  the payload ships with dispatch on and `retire_merged` off, a default install with a
  stub orchestrator nudges a Lead and delivers one digest, the same install with no
  orchestrator and no timer exits 0, holds the digest and prints one NOTE each in
  `doctor`, `update` keeps an explicit `enabled: false` and `true`, quiet hours and a
  pause, and personal configuration stays untouched; red-first loop-tick and dispatch
  tests cover a missing key reading as on; loop-tick, orchestrator, installed-docs,
  package-manifest and docs-site suites. Branch feat/ (after TASK-SWK-010 and
  TASK-SCL-006).

## 3. This repository and host (chore/)

- [ ] TASK-SWK-007 [routine] [~40 loc: host configuration only] Turn on merged-session retirement for this repository and install the Codex hook on the delivery host.
  Per design Decisions 9 and 13 and Product Owner decisions 1 to 3 and 6 in design.md.
  Dispatch is already on by default after TASK-SWK-006, so in this repository's tracked
  .nogging/config.json set only `session_dispatch.retire_merged` to true, leaving
  `enabled` absent or true, and commit only that; the template default for
  `retire_merged` stays false. On the delivery host, run `nogg session-hooks install --agent codex`,
  which the Product Owner approved, and record `session-hooks status`. The operator or
  the Orchestration Agent then restarts the
  orchestrator from an external shell so the budget applies, once it is idle. Remove the
  orchestrator's remaining background waiters. Needs a --full-access Lead; if it cannot
  reach the personal Codex configuration, record a blocking discovery and hand the
  commands to the Orchestration Agent. Check: doctor shows the dispatcher running with
  no FAIL and no missing-orchestrator or missing-timer NOTE; `session dispatch --dry-run --json` output as evidence; scripts/test. Branch
  chore/ (after TASK-SWK-006).

## 4. Live acceptance (test/)

- [ ] TASK-SWK-008 [complex] [~150 loc: live acceptance report on the delivery host] Live session-wake acceptance with real Claude Code, Codex and Pi sessions.
  Per design Decision 14: a host-capable Claude --full-access Lead runs it on this
  host, on throwaway Beads, recording versions of all four tools. One short real
  supervised session each on Claude Code, Codex and Pi shows: `turn_end` with an excerpt
  in `session watch`; a real stop guard continuing a Lead with a dirty tree on each
  runtime; a `session signal blocked` from the Codex sandbox reaching a digest; a fixed
  nudge landing only when idle; a red check nudging the Lead; a green check producing
  `ready_for_review`; two items coalesced into one wake; a merged session retired when
  enabled; a keep-warm answered in one line with no tool call; a pause of a few minutes
  that suppresses it and ends in one resume digest; a quiet-hours window holding an item; and, on a scratch consumer with no `session_dispatch.enabled` key, that dispatch reads as on, and with the orchestrator stopped holds its digest and prints the one `doctor` NOTE.
  Measure one warm and one cold wake to report how the quota weights a cache read against
  a write. Verify the host facts planning could not observe without a model turn: the
  Codex hook runs from a Lead worktree with NOGG_SESSION_ROOT set, and whether native
  idle compaction fires at the new threshold or the precompact fallback is what acts.
  Then measure a comparable period against the baseline in design.md: wakes, messages
  per wake, context, and tokens, both raw and in list-price equivalents. Never stop the
  shared tmux server or the Orchestration Agent. Check:
  docs/acceptance/<date>-session-wake.md with honest pass, fail or skipped results and
  an empty Signed-off-by. Branch test/ (after TASK-SWK-007).

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` means A depends on
B): 002<-001; 003<-002; 004<-003; 005<-004; 009<-005; 010<-009; 006<-010 (006<-005 stays
and is implied); 007<-006; 008<-007. Two edges
reach into `scheduled-loops`: 005<-TASK-SCL-005 for the idle-only send helper, and
006<-TASK-SCL-006 for the timer. TASK-SWK-001 to 004 need neither, and
`session dispatch --once` works by hand, so that work can start while `scheduled-loops`
finishes. There is no edge into `pi-extensions-glm-usage`, `dual-runtime-orchestrator`
or `configurable-agent-routing`; file overlaps are resolved by rebasing onto develop
and keeping both sides, as design Decision 12 states.

Branches are `<type>/session-wake` with these lanes: feat/ 001, 002, 003, 004, 005, 009, 010,
006 in sequence; chore/ 007; test/ 008. A lane's next task reuses its prefix only after the
previous branch is integrated and deleted. Before allocating a dependent worktree,
verify that every prerequisite execution commit is integrated into develop; Bead closure
alone is not enough.

## Execution contract

A task's first line is its Bead title. Its full slice is that line plus the indented
paragraph under it, the design Decisions it names, design Decision 1, and the matching
requirements in specs/. The Main Worker claims each task and implements it only in its
own allocated worktree on its lane branch, in several commits within the configured
commit range. Write the tier classification to the Bead note on every launch, including
Pi launches. Tasks marked [security] change authority, hook trust or text that reaches a
full-access session. A Claude Lead gets a code-reviewer pass before commit. On a Codex or
Pi Lead, the Orchestration Agent's review on the pull request is the accepted form
(Product Owner decision 4), and no kickoff tells that Lead to launch a reviewer session.
Every suite is offline (no real agent, Dolt, bd, shared
tmux or herdr server, systemd or network; private sockets; injected clocks and openers).
Test in stages: the tests of the changed files while working, those tests plus lint
before each commit, and the suites a task names once per Bead. The full `scripts/test` is
CI's job. Run a long command as one blocking call (`./scripts/nogg run-quiet -- <command>`),
never polled. Then push the lane branch and open the pull request against develop. Only
then run bd close and `scripts/nogg task-done`, and append every SHA and the evidence to
the Bead. A Codex Lead needs --full-access or --profile trusted to reach the shared Dolt
server. Agents never hand-edit OpenSpec. Discoveries carry the discovery label and prose.
Prompts, fixtures and docs contain no email address and no real key, and the owner is
named only as Jonas or JoMe92. Enabling user units and restarting the orchestrator stay
with the operator or the Orchestration Agent. Nobody signs human acceptance.
