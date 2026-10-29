## 1. Engine and definitions (feat/)

- [x] TASK-SCL-001 [standard] Pure schedule engine module.
  Per design Decisions 1 and 3: add scripts/lib/loop_schedule.py with no I/O.
  It parses and validates a schedule object (`every` m/h/d/w with its `start`
  forms, `at`, `days`, `windows`, `grace`) and raises ValueError naming the
  key. It provides `next_slots`, `due` (the latest due slot plus the count,
  first and last of the older missed ones) and `deadline` (grace, next slot,
  window end). It implements the daylight-saving gap and overlap rules and the
  weekday-of-the-window-opening-date rule. It is loaded beside scripts/nogg like
  session_backend and shipped in bin/lib/manifest.js. Check: new
  scripts/loop-schedule.test.sh, red first, which drives the module with
  injected clocks through every scenario of the schedule requirement, including
  the Europe/Berlin transitions on 2026-10-25 and 2027-03-28 and a UTC zone;
  package-manifest suite; scripts/test. Branch feat/.

- [x] TASK-SCL-002 [standard] [security] Loop definitions, prompt checks and validation.
  Per design Decisions 1, 2, 4 and 8: add scripts/lib/loop_config.py (pure,
  shipped in the manifest). It loads `loops_file` (new config key, default
  `.nogging/loops.json`, added to templates/nogging-config.json) with
  schema_version 1, refuses duplicate and unknown keys, and requires an IANA
  timezone. It applies the scheduler defaults and the per-loop fields with
  mode-specific rules. Send: target orchestrator only, with no agent, tier or
  authority. Launch: agent and tier required, authority restricted or trusted,
  never the orchestrator profile or the autonomous or orchestrator prompt. It
  enforces the multi_machine host rule and the prompt-file rules: size, UTF-8,
  email, secret_values(), _SECRET_ASSIGN_RE, token shapes and PEM headers. Errors
  name file, line and rule and never echo the match. It computes the canonical
  approval hash. Wire `nogg validate` and `doctor` to FAIL on an invalid file.
  Per Product Owner decision 1, set this repository's own .nogging/config.json
  `loops_file` to `.nogging/state/loops.json` (host-local, gitignored); the
  template default stays `.nogging/loops.json`. Document `loops_file` in
  docs/configuration.md, whose key coverage the docs-site suite checks. Check: new
  scripts/loop-config.test.sh, red first, covering every scenario of the
  definitions, prompts, authority-refusal and multi-machine requirements, plus
  the host-local layout (prompts in `.nogging/state/loops/` beside the runtime
  files) and a template default of `.nogging/loops.json`; nogg.test.sh;
  scripts/test. Branch feat/ (after TASK-SCL-001).

- [ ] TASK-SCL-003 [complex] [security] The loop CLI, host state and approvals.
  Per design Decisions 2, 5, 8 and 9: add the `nogg loop` group.
  - `add` takes schedule, run, usage and host options plus `--prompt-file` or
    `--prompt`. On first use it writes the host timezone, it refuses an
    existing name, and it approves what it writes. It writes into the
    configured `loops_file` and prints a commit reminder only when that path is
    not gitignored, so a host-local file gets none.
  - `list` and `log` have `--json`; `log` also has `--limit` and reads an
    absent or empty runs.jsonl cleanly. `show` is the third read command.
  - `pause` and `resume` change host-local state only. `approve` prints the
    authority before it records. `remove` keeps the run log.

  state.json and approvals.json live under `.nogging/state/loops/` in the main
  checkout, are written atomically, and are resolved canonically from any
  checkout. Approvals record the OS user name only. Mutations are refused when
  calling_session_record() proves a session other than the orchestrator; the
  orchestrator may add and approve (Product Owner decision 2). Add `## loop`
  and one `### loop <command>` entry per new subcommand to docs/commands.md, in
  `nogg --help` order, as the docs-site suite requires. Check: new
  scripts/loop-cli.test.sh, red first: fake session records for the refusal
  cases and an allowed orchestrator approve, a hand edit and a simulated merge
  leaving a loop unapproved, `add` and `remove` in the host-local layout leaving
  the runtime files intact, and JSON output shape; scripts/test. Branch feat/
  (after TASK-SCL-002).

## 2. Loop session role (fix/)

- [ ] TASK-SCL-004 [standard] [security] The internal loop session role and its launch prompt.
  Per design Decisions 1 and 4: add role `loop` to session launch for internal
  callers only. It has no Bead; its record carries `loop_name` and
  `loop_run_id`; its name is `sf-loop-<name>-<nonce>` through the safe-name
  helper; its working directory is the main checkout; it takes a caller-supplied
  kickoff message. The command floor and the openspec fence always apply,
  restricted is the default, and the orchestrator profile and the autonomous
  and orchestrator prompts are refused. `session launch --role loop` on the
  command line is refused before side effects with a pointer to
  `nogg loop run-now`. `session list` shows `loop:<name>`. Add `loop` to the
  usage-gate roles (gated by default, allowed in exclude_roles), and write the
  `.nogging/launch-prompts/loop.md` persona. Check: new
  scripts/session-loop-role.test.sh, red first, with stub agents on a private
  socket: floor and fence present in the restricted and trusted effective
  settings, profile and prompt refusals, record fields, CLI refusal, gate role;
  usage-gate and launch suites green; scripts/test. Branch fix/. No
  prerequisites.

## 3. Scheduler (feat/)

- [ ] TASK-SCL-005 [complex] Scheduler tick, run log, usage admission and send runs.
  Per design Decisions 5, 6, 7 and 9: add `nogg loop tick` and `run-now`.
  - The tick runs only in the main checkout and is refused in every supervised
    session. It takes a non-blocking flock on `.nogging/locks/loops.lock` and
    exits 0 when busy. It records last_tick.
  - Per loop it evaluates from last_evaluated, which starts at the approval
    time, and coalesces missed slots. Hard skips: disabled, paused, suspended,
    unapproved, other host, and the usage gate with `max_used_percent` and
    `on_unknown`. Deferrals last until the deadline and are logged only when the
    reason changes. A `starting` event is written before any side effect.
  - Send runs go to the canonical orchestrator only when it is idle, through the
    verified send path. They complete after two idle ticks and are logged
    unconfirmed after max_runtime.
  - Failures retry after 2, 4 and 8 minutes. Consecutive failures suspend the
    loop. Interrupted `starting` events are reconciled.
  - The runs.jsonl writer rotates the log and writes no prompt text.
  - docs/commands.md gains `### loop tick` and `### loop run-now` in
    `nogg --help` order.

  Check: new scripts/loop-tick.test.sh, red first, with an injected clock, a
  private socket, a stub orchestrator that is idle, working, needs_input or
  absent, and fixture usage observations (allow, cap denial, budget denial,
  unknown warn and deny); docs-site suite; scripts/test. Branch feat/ (after
  TASK-SCL-003).

- [ ] TASK-SCL-006 [complex] [security] Launch-mode runs.
  Per design Decisions 4, 6 and 7: add launch runs to the tick and run-now.
  - Admission: the max_active_launch_runs deferral, then a launch through the
    loop role with the loop's agent, tier, model, effort and authority and a
    kickoff of the header plus the prompt. The normal launch admission applies;
    exit 75 is a hard skip. Never `--ignore-usage-gate`, and never another tier,
    model, agent or a higher authority.
  - Failures: a missing agent binary, a tmux server that is down, or a kickoff
    that is refused or times out is retried. A session whose kickoff failed is
    stopped and retired.
  - Completion: after two idle ticks the session is stopped, cleaned up and its
    archived log path recorded. A session that ends on its own is a failure. A
    stale run is stopped and retired. Interrupted starts are reconciled by
    loop_run_id.

  Check: new scripts/loop-launch.test.sh, red first, with stub agents on a
  private socket: completed and retired, kickoff refused, binary missing then
  present, a hang past max_runtime, a gate denial, two launch loops under a
  limit of 1; loop-tick suite green; scripts/test. Branch feat/ (after
  TASK-SCL-005 and TASK-SCL-004).

## 4. Units, diagnostics and orchestrator guidance (chore/, refactor/)

- [ ] TASK-SCL-007 [standard] Loop scheduler units, installer lines and doctor health.
  Per design Decisions 5 and 9 and the installer requirement: add
  templates/systemd/nogg-loops.service.tmpl and nogg-loops.timer.tmpl (oneshot
  `scripts/nogg loop tick`, minutely, Persistent=false). Add the manifest
  systemd entries, the next-steps enable line, the remove disable line and the
  --no-systemd skip. In doctor: the timer state through systemctl when
  available, a WARN for an enabled timer whose last_tick is older than
  5 minutes, a NOTE when enabled loops exist but the timer is missing or
  disabled, and a WARN for unapproved, suspended and stale-run loops. Check:
  extend scripts/cli.test.sh (rendered units, enable line, --no-systemd,
  update leaves .nogging/loops.json and .nogging/loops/ unchanged) and add
  scripts/loop-doctor.test.sh with a systemctl stub; installer and
  next-steps suites green; scripts/test. Branch chore/ (after TASK-SCL-005).

- [ ] TASK-SCL-008 [routine] Orchestrator guidance for loops.
  Per design Decision 10 and the orchestration-agent requirement: edit
  .nogging/launch-prompts/orchestrator.md and .claude/commands/orchestrate.md
  (and every other shipped orchestrator entry point present on develop). The
  text says: recurring work goes only into `nogg loop`, never CronCreate or
  `/loop`; a `[nogg loop <name> run <id>]` message is a bounded,
  orchestrate-only run that ends with a short report; propose `nogg loop add`
  for recurring requests; add or approve only on an explicit Product Owner
  instruction (allowed per Product Owner decision 2); the recipe that migrates a
  session-only loop, such as the 5-hour issue loop, to `every: 5h, start: 02:07`
  with `nogg loop add` into whichever `loops_file` the repository configures.
  The shipped text stays generic and quotes no host prompt. Rebase onto any
  landed dual-runtime-orchestrator prompt edits.
  Check: extend scripts/orchestrator.test.sh or scripts/commands.test.sh with
  content assertions; scripts/test. Branch refactor/ (after TASK-SCL-005).

## 5. Documentation (docs/)

- [ ] TASK-SCL-009 [standard] Scheduled loops guide and operator docs.
  Per design Decision 11: add consumer-copied docs/scheduled-loops.md. It
  covers the concepts, the file format, the tracked default and the host-local
  `loops_file` layout, the night-window, five-day and orchestrator examples,
  modes and authority (restricted stops at the first Bash prompt; launch mode is
  inspect-and-report only in v1), approval (including by the orchestrator on
  the Product Owner's instruction), the CLI, the run policy, usage,
  `--no-systemd` and external schedulers, multi-machine, troubleshooting and the
  run-log JSON read contract. Place it under Guides in docs/_config.yml. Add it
  to manifest docs and the package files. Add short sections to
  operating-model, architecture, security-model and failure-recovery, link the
  guide from the `loop` entries in commands.md and the `loops_file` entry in
  configuration.md, and add a CHANGELOG Unreleased entry. Check: docs-site suite; installed-docs and
  package suites; new scripts/loop-docs.test.sh (examples parse with the real
  validator, no email address); nogg validate; scripts/test. Branch docs/
  (after TASK-SCL-006, TASK-SCL-007 and TASK-SCL-008).

## 6. Delivery-host acceptance (test/, host-capable Lead)

- [ ] TASK-SCL-010 [complex] Live scheduled-loops acceptance and migration of the orchestrator loop.
  Per design Decision 12: a host-capable Claude --full-access Lead runs it on
  this host. The operator or the Orchestration Agent enables
  nogg-loops-<slug>.timer, because systemctl is denied to Leads. Migrate
  orchestrator-issues host-local (Product Owner decision 1): first confirm that
  develop's .nogging/config.json sets `loops_file` to `.nogging/state/loops.json`
  (TASK-SCL-002), then run `nogg loop add` in the main checkout, which writes the
  definition there and the Product Owner's current prompt to
  `.nogging/state/loops/orchestrator-issues.md`, and confirm that `git status`
  shows neither file. Then observe: a scheduled fire, a busy deferral, a
  routine Codex launch run completed and retired, a usage skip forced by
  max_used_percent 1, an orchestrator restart between slots, and a timer
  restart. Remove the temporary loops and keep orchestrator-issues. The
  orchestrator then deletes its session cron. Never stop the shared tmux server
  or the orchestrator. Check: docs/acceptance/<date>-scheduled-loops.md with
  versions, honest outcomes and an empty Signed-off-by, naming the loop and its
  schedule but quoting no prompt text; scripts/test. Branch test/ (after
  TASK-SCL-009).

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` means A
depends on B): 002<-001; 003<-002; 005<-003; 006<-004, 006<-005; 007<-005;
008<-005; 009<-006, 009<-007, 009<-008; 010<-009. TASK-SCL-001 and TASK-SCL-004
start in parallel. TASK-SCL-006, TASK-SCL-007 and TASK-SCL-008 run in parallel
after TASK-SCL-005. There is no edge into another change. The coordination
rules with branded-docs-site and dual-runtime-orchestrator are in design
Decision 11.

Branches are `<type>/scheduled-loops` with these lanes: feat/ 001, 002, 003,
005, 006; fix/ 004; chore/ 007; refactor/ 008; docs/ 009; test/ 010. A lane's
next task reuses its prefix only after the previous branch is integrated and
deleted. Before allocating a dependent worktree, verify that every
prerequisite execution commit is integrated into develop; Bead closure alone is
not enough.

## Execution contract

A task's first line is its Bead title. Its full slice is that line plus the
indented paragraph under it, the design Decisions it names, design Decision 1,
and the matching requirements in specs/. The Main Worker claims each task and
implements it only in its own allocated worktree on its lane branch. Tasks
marked [security] change authority, approval or secret handling and get a
code-reviewer pass before commit. Every suite is offline in scripts/test (no
systemd, Dolt, bd or shared tmux server; private sockets; injected clocks). Run
the task's named checks; the full scripts/test runs in CI. Then commit with a
Conventional subject ending in the real Bead token, push the lane branch and open
the pull request against develop. Only then run bd close and
`scripts/nogg task-done`, and append the SHA and evidence to the Bead. A Codex
Lead needs --full-access or --profile trusted to reach the shared Dolt server.
Agents never hand-edit OpenSpec. Discoveries carry the discovery label and
prose. Prompts, fixtures and docs contain no email address, and the owner is
named only as Jonas or JoMe92. Enabling user units stays with the operator or
the Orchestration Agent. Nobody signs human acceptance.
