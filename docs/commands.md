# Command reference

This page lists every `scripts/nogg` subcommand for operators, Lead Agents and
the Planning Agent: what it is for, the forms you will use most, which role
runs it, and where to read more. It follows `scripts/nogg --help`, one section
per top-level subcommand. Run `./scripts/nogg <command> --help` for the full
option list of any entry.

The guides stay the place to learn a workflow. The command tables in
[Running work in sessions](running-work-in-sessions.md#quick-reference) and the
[Operating model](operating-model.md#commands) are shorter and link here.

## credential-helper

**Purpose.** Git credential helper that mints a short-lived GitHub App token in
memory for one agent identity, so no token is stored or put on a command line.

**Common forms.**

```bash
./scripts/nogg credential-helper <slug> get
```

**Used by.** Git itself, after an operator configures an agent identity. Agents
do not call it by hand.

**Read more.** [Agent identities](agent-identities.md).

## repo-state

**Purpose.** Print the canonical repository state (branch, worktree, planning
lock and related facts) without writing anything. It resolves the shared
checkout from inside any linked worktree.

**Common forms.**

```bash
./scripts/nogg repo-state --cwd "$PWD"
```

**Used by.** Any role, when it is unclear which checkout it is standing in.

**Read more.** [Failure recovery](failure-recovery.md).

## token-usage

**Purpose.** Local token accounting for supervised sessions: collect, report,
export, import and sync. It reports tokens only, not cost or quota percent.

**Common forms.**

```bash
./scripts/nogg token-usage status
./scripts/nogg token-usage report
./scripts/nogg token-usage report --group-by bead --from 2026-10-01 --to 2026-11-01   # tokens per Bead and per production line
./scripts/nogg token-usage session <name>
```

**Used by.** The operator and the Orchestration Agent. `sync` is for a trusted
operator or orchestrator only.

**Read more.** [Token usage](token-usage.md).

## usage

**Purpose.** Inspect read-only quota observations for an agent, and optionally
install the statusline capture used by the launch usage gate.

**Common forms.**

```bash
./scripts/nogg usage --agent claude
./scripts/nogg usage --agent codex --model <model-name> --json
./scripts/nogg usage --agent pi
./scripts/nogg usage install-statusline [--dry-run] [--json]
./scripts/nogg usage uninstall-statusline [--dry-run] [--json]
```

`--dry-run` prints the intended `settings.json` diff and writes nothing;
`uninstall-statusline` restores only the previous `statusLine` key.

For `--agent pi` the command reads the shared Z.ai snapshot and, when it is
stale, runs one bounded probe through Pi's own key resolver; set
`PI_NOGG_USAGE_PROBE=0` to make it cache-only.

**Used by.** The operator and the Orchestration Agent.

**Read more.** [Usage limits](usage-limits.md) (see [Pi via Z.ai](usage-limits.md#pi-via-zai)) and the
[launch usage gate](running-work-in-sessions.md#launch-usage-gate).

## validate

**Purpose.** Strict check that the OpenSpec tasks and the Beads that map to them
agree. It exits non-zero on any defect.
It also adds a task sizing NOTE for open tasks whose `[~N loc]` estimate is
below the configured minimum without a reason, or that mostly carry no estimate
(see [task-sizing](#task-sizing)). A NOTE never changes the exit code.

**Common forms.**

```bash
./scripts/nogg validate
```

**Used by.** The Planning Agent before it commits a change, and a Lead Agent
before it finishes.

**Read more.** [Operating model](operating-model.md).

## doctor

**Purpose.** Report tool availability, locks, mapping errors, session helpers
and the last sync failure, without modifying data. Run it first when something
looks wrong.

**Common forms.**

```bash
./scripts/nogg doctor
./scripts/nogg doctor --recover
./scripts/nogg doctor --sandbox
```

**Used by.** Everyone. `--recover` adds the interrupted-run checks; `--sandbox`
adds slow probes inside the Codex sandbox.

**Read more.** [Failure recovery](failure-recovery.md).

## audit

**Purpose.** Run the same invariant checks as `doctor` and write a timestamped
local report.

**Common forms.**

```bash
./scripts/nogg audit
```

**Used by.** The operator and the Planning Agent, after a mapping or Bead
repair.

**Read more.** [Failure recovery](failure-recovery.md).

## recover

**Purpose.** Read-only scan for an interrupted run: Beads left in progress,
branches ahead of the base branch, worktrees nobody owns. It exits non-zero
when a decision is needed.

**Common forms.**

```bash
./scripts/nogg recover
```

**Used by.** A Lead Agent before `bd ready` when resuming, and the operator
after a crash or a tool switch.

**Read more.** [Operating model](operating-model.md#resuming-an-interrupted-run)
and [Failure recovery](failure-recovery.md).

## sync

**Purpose.** Reconcile Beads and OpenSpec state. The sync daemon runs it on a
timer; `--now` forces a pass on demand.

**Common forms.**

```bash
./scripts/nogg sync --now
```

**Used by.** The operator, through `/sync-now`. It reports lock contention
instead of retrying.

**Read more.** [Operating model](operating-model.md) and
[Failure recovery](failure-recovery.md).

## discoveries

**Purpose.** List the discoveries Leads recorded on Beads, blocking ones first.
`--ack` records that a planning session has seen them.

**Common forms.**

```bash
./scripts/nogg discoveries
./scripts/nogg discoveries --ack <bead-id>
```

**Used by.** The Planning Agent, through `/discovery-review`.

**Read more.** [Operating model](operating-model.md#discoveries).

## plan-begin

**Purpose.** Take the planning lock, which makes `openspec/` writable for the
Planning Agent only.

**Common forms.**

```bash
./scripts/nogg plan-begin
```

**Used by.** The Planning Agent. `--force` is a last resort for a stale lock.

**Read more.** [Operating model](operating-model.md) and
[Worktree workflow](worktree-workflow.md).

## plan-end

**Purpose.** Release the planning lock and make `openspec/` read-only again.
Always run it before the planning worktree is retired.

**Common forms.**

```bash
./scripts/nogg plan-end
```

**Used by.** The Planning Agent, from the planning worktree.

**Read more.** [Operating model](operating-model.md) and
[Worktree workflow](worktree-workflow.md).

## materialize

**Purpose.** Turn the committed tasks of an OpenSpec change into Beads. It is
idempotent, so a crash between commit and materialize is safe to repeat.

**Common forms.**

```bash
./scripts/nogg materialize <change>
```

**Used by.** The Planning Agent, after the change is committed.

**Read more.** [Operating model](operating-model.md).

## task-done

**Purpose.** Tick the `tasks.md` line that maps to a closed Bead. It is the last
step of the Lead close protocol.

**Common forms.**

```bash
./scripts/nogg task-done <bead-id>
```

**Used by.** A Lead Agent, after `bd close`.

**Read more.** [Operating model](operating-model.md) and
[Failure recovery](failure-recovery.md).

## task-sizing

**Purpose.** Print the Bead and commit line ranges in effect: the `task_sizing`
key of `.nogging/config.json`, or its defaults (Bead 400–1000 production lines,
commit 100–600 lines). Each range says whether it is configured or the default.

**Common forms.**

```bash
./scripts/nogg task-sizing
```

**Used by.** The Planning Agent when it sizes tasks, and a Lead Agent when it
splits a Bead into commits.

**Read more.** [Configuration](configuration.md#task_sizing) and
[Operating model](operating-model.md#task-sizing).

## run-quiet

**Purpose.** Run one long command, such as a test suite or a build, as a single
blocking call that prints a single line. The command's stdout and stderr go to a
log file in full, and its stdin is `/dev/null`. On success it prints
`ok: <command> (<seconds> s)` and removes its default log. On failure it prints
a `FAIL (exit <code>)` line with the log path and the last lines of the log (40
unless `--tail N` says otherwise), then exits with the command's exit code. A
death by signal N exits 128+N, and a command that is not found exits 127. The
default log is a new `nogg-run-quiet.*.log` file in `$TMPDIR`; `--log PATH`
names one that is always kept. The command runs without a shell, so wrap a
pipeline in `bash -c '...'`. SIGINT and SIGTERM are passed on to the command.
The `--` before the command is required. Credential-looking values (a
`*TOKEN*=`/`*SECRET*=` argument, a `Bearer` header, a known token prefix) are
masked in the printed command, never in the log.

A deny rule only sees `nogg run-quiet`, so the wrapper applies them itself: the
command floor (`sudo`, `rm -rf`, `dd`, `mkfs`, `shutdown`, `reboot`) and, inside
a supervised session, that session's own `Bash(...)` deny rules (for example a
restricted profile's `git push`), found by the session's name in this
checkout's or the canonical checkout's session store; a named session with no
record is refused. A denied command anywhere in the argv (behind
`env`, `timeout`, `xargs` or `find -exec`) or in a `<shell> -c` script is
refused with exit 2 before anything runs.

**Common forms.**

```bash
./scripts/nogg run-quiet -- scripts/test
./scripts/nogg run-quiet --tail 80 --log /tmp/build.log -- npm run build
```

**Used by.** A Lead Agent or specialist that runs a long command. Waiting is one
blocking call, so the agent never polls the running command. A passing suite
leaves one line in the context, not its whole output.

**Read more.** [Operating model](operating-model.md).

## test

**Purpose.** Run one test stage through `run-quiet`, under its budget and the
session's deny rules, and leave one record. `changed` and `commit` cover the
tracked changes and untracked files, `bead` adds the branch's diff from its
merge-base, and `full` runs everything. Commands come from `testing.stages`, or
from fallbacks that keep an existing repository working. A stage that ran nothing
prints `skipped: <stage> ran no tests (<reason>)` and exits 0. A run above its
budget prints an `over budget:` line and keeps its exit code. `bead` and `full`
hold one of the host-wide heavy slots and print their five slowest tests.

`full` is refused with exit 77 wherever CI runs it, unless `--release` (an
operator shell or the Orchestration Agent), `--nightly` (outside any supervised
session) or `--allow-full "<reason>"` permits it. The exit code is the stage's
own, 77 when refused and 75 when no heavy slot came free in time.

`bead` also prints the Bead's test-line count against `task_sizing.bead_test_lines`
and ends with the test-integrity rule; `integrity` runs that rule alone, and
`testing.integrity: enforce` makes an uncleared finding exit 1. `report` prints the
daily cost and trend of the run records. The `doctor` NOTEs read the same records.

**Common forms.**

```bash
./scripts/nogg test changed
./scripts/nogg test commit
./scripts/nogg test bead [--base <ref>] [--bead <id>]
./scripts/nogg test full --allow-full "migration touches every test"
./scripts/nogg test full --release
./scripts/nogg test integrity [--base <ref>]
./scripts/nogg test report [--days N] [--json]
./scripts/nogg test nightly
```

**Used by.** A Lead Agent or specialist at each testing moment, the operator
before a release.

**Read more.** [Test control](test-control.md) and
[Configuration](configuration.md#testing).

## session-hooks

**Purpose.** Install, inspect or remove the one user-level Codex `Stop` hook that
gives Codex Leads the stop guard. It merges a constant entry into
`~/.codex/hooks.json`, records trust through Codex's own app-server and reads the
result back from `hooks/list`. `status` reports `trusted`, `untrusted`, `modified`
or `missing`, says `unknown` when Codex cannot be asked, and never fails. `remove`
reverses both and leaves every other hook, and its trust, alone.

**Common forms.**

```bash
./scripts/nogg session-hooks status --agent codex
./scripts/nogg session-hooks install --agent codex
./scripts/nogg session-hooks remove --agent codex
```

**Used by.** The operator, once per machine. `init` and `update` never do this,
because it writes personal configuration, and because installing it removes the
Codex sandbox as a boundary on that host: see the known limit in the security
model first.

**Read more.** [Using Nogging with Codex](using-with-codex.md) and the
[Security model](security-model.md#the-codex-stop-hook).

## codex-prompts-link

**Purpose.** Link the repository's Codex prompts into your Codex home as
`nogging-<name>.md` so Codex can run them as slash prompts.

**Common forms.**

```bash
./scripts/nogg codex-prompts-link
./scripts/nogg codex-prompts-link --unlink
```

**Used by.** The operator, once per machine, when using Codex.

**Read more.** [Using Nogging with Codex](using-with-codex.md).

## pi-ext

**Purpose.** List the Nogging Pi extensions under `.pi/nogging/extensions/`,
and install or remove one for standalone Pi through Pi's own package command.
`list` is read-only: it shows whether `pi_extensions` enables each extension
and whether your personal Pi `settings.json` (under `PI_CODING_AGENT_DIR` or
`~/.pi/agent`, never `auth.json`) names its path. `install` and `remove` run
`pi install` or `pi remove` with the main checkout's
`.pi/nogging/extensions/<name>/index.ts`, even from a linked worktree, so the
entry survives worktree cleanup. They refuse an unknown name or a missing `pi`,
never edit Pi's settings themselves and never pass `-l`.

**Common forms.**

```bash
./scripts/nogg pi-ext list
./scripts/nogg pi-ext install glm-usage
./scripts/nogg pi-ext remove glm-usage
```

**Used by.** The operator, once per machine, when using standalone Pi. `init`
and `update` never do this, because it writes personal configuration. `doctor`
prints a NOTE for an enabled extension that is not installed, for
`npm:pi-glm-usage` configured next to `glm-usage` (run `pi remove
npm:pi-glm-usage`), and for an install whose path no longer exists.

**Read more.** [Using Nogging with Pi](using-with-pi.md#enabling-optional-extensions--pi_extensions).

## models

**Purpose.** Print the model-selection table, look up the model and effort for
an agent and tier, or validate the table with `check`. It makes no live probe.

**Common forms.**

```bash
./scripts/nogg models
./scripts/nogg models --agent codex --tier standard
./scripts/nogg models check
```

**Used by.** Lead Agents, the Orchestration Agent and the operator.

**Read more.** [Model selection](model-selection.md).

## route

**Purpose.** Inspect the agent routing file: `check` validates it and exits
non-zero naming every error; without `check` it prints every role's entries
with their effective per-tier model and effort. It makes no live probe; the
launch decides.

**Common forms.**

```bash
./scripts/nogg route
./scripts/nogg route check
```

**Used by.** Lead Agents, the Orchestration Agent and the operator.

**Read more.** [Configuration](configuration.md#agent_routing_file).

## worktree

**Purpose.** Allocate and safely manage isolated Git worktrees, so each agent
works on its own checkout.

**Read more.** [Worktree workflow](worktree-workflow.md).

### worktree plan

Allocate a planning worktree from updated `origin/develop`.

```bash
./scripts/nogg worktree plan <planning-id> <description>
```

**Used by.** The Planning Agent, at the start of `/plan`.

### worktree implement

Allocate an implementation worktree for a Bead that is already claimed. It
refuses a Bead another Lead holds or may still hold, and refuses when it cannot
tell.

```bash
./scripts/nogg worktree implement <bead-id> <branch>
```

**Used by.** A Lead Agent, before it writes any code.

### worktree cleanup

Retire one clean worktree whose branch is integrated into `develop`. It refuses
a dirty or unintegrated one.

```bash
./scripts/nogg worktree cleanup <record>
```

**Used by.** The Planning Agent or operator, from the surviving shared checkout.
See [Stop and clean up](running-work-in-sessions.md#stop-and-clean-up).

### worktree rebase

Rebase an implementation worktree onto `origin/develop` with the safety checks
Nogging needs. Use it instead of `git rebase`.

```bash
./scripts/nogg worktree rebase [<record>] [--continue | --abort]
```

**Used by.** A Lead Agent whose branch fell behind. See
[Bring a Lead branch up to date](running-work-in-sessions.md#bring-a-lead-branch-up-to-date).

### worktree repair

Dry-run, or with `--apply` fix, a worktree whose recorded paths no longer
exist.

```bash
./scripts/nogg worktree repair <record>
./scripts/nogg worktree repair <record> --apply
```

**Used by.** The operator. See [Failure recovery](failure-recovery.md).

## pr

**Purpose.** Open or find the pull request for an implementation branch and
watch its required checks.

**Read more.** [Worktree workflow](worktree-workflow.md).

### pr open

Create, or locate, the open pull request that targets `develop`.

```bash
./scripts/nogg pr open --plan <change> --task <task-id> --validation "<what you ran>"
```

**Used by.** A Lead Agent once its work is committed and pushed.

### pr ci

Inspect the required checks of the pull request after the initial wait.

```bash
./scripts/nogg pr ci
```

**Used by.** A Lead Agent, to repair failing checks in the same worktree.

## orchestrator

**Purpose.** Run and inspect the always-on Orchestration Agent that a systemd
user service keeps alive.

**Read more.** [The always-on Orchestration Agent](running-work-in-sessions.md#the-always-on-orchestration-agent)
and [Operating model](operating-model.md#orchestration).

### orchestrator run

The idempotent supervisor the systemd unit runs. `--force` reclaims a lock only
after you have verified it is stale.

```bash
./scripts/nogg orchestrator run
```

**Used by.** The systemd unit, not you.

### orchestrator status

Show the unit's state, whether user lingering is on, the lock holder and the
live session.

```bash
./scripts/nogg orchestrator status
```

**Used by.** The operator.

### orchestrator stop

Stop and disable the unit, end the session and release the lock. Safe to repeat.

```bash
./scripts/nogg orchestrator stop
```

**Used by.** The operator.

### orchestrator restart

Restart the unit and relaunch the session with the current prompt and settings.
`--supervisor-only` keeps the live session.

```bash
./scripts/nogg orchestrator restart [--supervisor-only]
```

**Used by.** The operator.

## session

**Purpose.** Start and supervise agent sessions in a terminal backend (tmux, or
the experimental herdr backend), and steer, watch and retire them.

**Read more.** [Running work in sessions](running-work-in-sessions.md).

### session herdr-server

Start, or verify, the dedicated herdr server. The herdr backend is
experimental.

```bash
./scripts/nogg session herdr-server start
```

**Used by.** The operator, from the host. See
[Using Nogging with herdr](using-with-herdr.md).

### session launch

Start a supervised session for a role. It changes no Beads.

```bash
./scripts/nogg session launch --role lead --bead <bead-id>
./scripts/nogg session launch --role planning --planning-id <id> --description <description>
./scripts/nogg session launch --role lead --bead <bead-id> --agent codex --tier standard
```

Without `--agent`, a role with a list in the agent routing file launches the first
entry that passes; `--skip-agent <name>` skips an agent for that launch. See
[Running work in sessions](running-work-in-sessions.md#choosing-the-agent) and `route`
below.

**Used by.** The operator and the Orchestration Agent. A specialist cannot
launch sessions.

### session list

List every session with its reconciled state, agent, backend and launch
profile.

```bash
./scripts/nogg session list
```

**Used by.** The operator and the Orchestration Agent. See
[Watch without touching](running-work-in-sessions.md#watch-without-touching).

### session attach

Attach your terminal to a session. `--read-only` blocks input.

```bash
./scripts/nogg session attach <name> [--read-only]
```

**Used by.** The operator. See
[Attach and steer](running-work-in-sessions.md#attach-and-steer).

### session log

Print a session's log, or follow it, without attaching.

```bash
./scripts/nogg session log <name> --follow
```

**Used by.** The operator and the Orchestration Agent.

### session stop

Interrupt a session, end it after the grace period and record a terminal state.
Safe to repeat.

```bash
./scripts/nogg session stop <name> --reason "<why>"
```

**Used by.** The operator and the Orchestration Agent.

### session reap

Mark sessions whose backend session vanished as failed, so they can be cleaned
up. A live session is untouched.

```bash
./scripts/nogg session reap
```

**Used by.** The operator.

### session cleanup

Retire the record and archive the logs of a finished session. It refuses a live
one.

```bash
./scripts/nogg session cleanup [<name>] [--reap]
```

**Used by.** The operator and the Orchestration Agent. See
[Stop and clean up](running-work-in-sessions.md#stop-and-clean-up).

### session watch

Poll sessions and report progress, stalls and usage-limit events as lines or
JSON lines.

```bash
./scripts/nogg session watch
./scripts/nogg session watch --format jsonl --once
```

**Used by.** The operator and the Orchestration Agent.

### session send

Send a verified instruction into a running session.

```bash
./scripts/nogg session send <name> "<instruction>"
```

**Used by.** The operator and the Orchestration Agent. See
[Steering from outside](running-work-in-sessions.md#attach-and-steer).

### session nudge

Wake a session that has stopped on unsent input, optionally with a message.

```bash
./scripts/nogg session nudge <name> --message "<instruction>"
```

**Used by.** The operator and the Orchestration Agent.

### session kickoff

Deliver the first instruction once a launched session is ready. `--change`
authorises a Lead to execute a whole change instead of one task.

```bash
./scripts/nogg session kickoff <name> [--message "<instruction>"] [--change <change>]
```

**Used by.** The operator and the Orchestration Agent.

### session sweep

Read-only liveness report for running sessions that have a Bead. `--checks`
adds a remote look at each pull request's checks.

```bash
./scripts/nogg session sweep [--checks]
```

**Used by.** The operator and the Orchestration Agent. See
[Explicit CI check observations](running-work-in-sessions.md#sweep-work-scope-and-integration).

### session checks-ack

Acknowledge the cached check observation of a session, so it stops showing as
unseen.

```bash
./scripts/nogg session checks-ack <name> [--fingerprint <fingerprint>]
```

**Used by.** The operator and the Orchestration Agent, after reviewing the
checks.

### session resume-when-ready

Wait out an account-wide usage limit, then send the session its resume message.

```bash
./scripts/nogg session resume-when-ready <name> [--message "<instruction>"]
```

**Used by.** The operator and the Orchestration Agent. See
[Usage limits](usage-limits.md).

### session emit

Append a normalized lifecycle event to the calling session's own event file.
Agent hooks call it; it only works inside a launched session. Hook JSON on
stdin is read up to 64 KiB, invalid input is tolerated, and only a fixed set
of fields is kept: the source, an error kind, the notification type, the count
of background tasks and a redacted one-line excerpt of the last agent message
(at most 300 characters). The file is rotated at 256 KiB. A `Notification`
other than a question (for example `idle_prompt`) records nothing.

```bash
./scripts/nogg session emit <event>
./scripts/nogg session emit turn_end --guard [--runtime <agent>]
```

The events are `turn_start`, `turn_end`, `needs_input`, `turn_error` and
`session_end`; Claude Code's launch settings wire them to `UserPromptSubmit`,
`Stop`, `Notification`, `StopFailure` and `SessionEnd`. `--guard` is the `Stop`
hook of an autonomous Lead: a stop with gaps prints `decision: "block"` once and
records `guard_continue` instead of `turn_end`. `--runtime` names the hook's own
runtime, so a Codex child inside a Claude session cannot speak for it.

**Used by.** Agent hooks, not people.

### session capabilities

Report what a Lead of an agent and authority can do: launch child sessions, reach
Dolt, push, open a pull request, rebase without an operator, and run in-process
specialists. Every answer is derived from what `session launch` resolves, and one
that cannot be established reads `unknown`, which a caller treats as no.

```bash
./scripts/nogg session capabilities --agent codex --profile trusted
./scripts/nogg session capabilities --agent claude --profile restricted --json
```

**Used by.** The Orchestration Agent, before it writes a requirement into a
kickoff.

### session completion-check

Report this session's gaps: `dirty` (uncommitted or untracked changes), `unpushed`
(no upstream, or commits ahead) and `no-signal`. It uses local git only and reads
the Bead's implementation worktree when one is allocated. It exits 1 with gaps and
0 without them, and it exits 0 on any internal error, because a guard fails open.

```bash
./scripts/nogg session completion-check
./scripts/nogg session completion-check --json
```

**Used by.** The stop guard on every runtime, and a Lead checking itself.

### session signal

State that this supervised session is `blocked` or `done`, with a reason of at
most 300 characters. It needs neither the network nor Dolt, so a restricted
Lead can run it, and it refuses outside a supervised session. A signal is a
fact for `session watch`, which reports it as its own event; it never changes
the classified state, so a session that signalled still reads `idle`. The
command prints whether dispatch is on and what to do next.

```bash
./scripts/nogg session signal blocked "worktree rebase refused: needs an unfenced operator"
./scripts/nogg session signal done "PR #321 open"
```

**Used by.** A Lead, at the end of its work. The Bead note still carries the
prose.

### session dispatch

Run one deterministic follow-up pass, with no model. It reads every live Lead with a
Bead and every planning session, decides from their real state, and acts: an idle
Lead with gaps or red CI gets a fixed nudge, and what needs a decision is queued in
`.nogging/state/dispatch/queue.json`. Nothing depends on a hook having fired, and a
pass that is repeated does nothing twice. A fact it cannot read, such as a failing
`gh` or `bd`, is `unknown` and produces no action. It never merges, answers a prompt,
launches a session or chooses a model.

Every pass re-evaluates the queue, so a condition that clears before delivery simply
disappears. What stays ready goes to the orchestrator as one digest of at most 1.5 KiB
that starts with `[nogg wake`, through the same verified send as a `send` loop and only
while the orchestrator sits at its prompt: idle, or waiting on nothing but its own
background job. A busy or absent orchestrator, or typed input in its composer, keeps
the items for a later pass. The `wake` keys of
[`session_dispatch`](configuration.md#session_dispatch) set the timing.

Dispatch is on by default. With `session_dispatch.enabled: false` it prints that it is
disabled and does nothing. It runs
only in the main checkout and is refused in every supervised session, except with
`--dry-run`, which reports the actions and sends, stops and writes nothing. When
another pass holds `.nogging/locks/dispatch.lock` it exits 0. Every run is one pass,
and `--once` says so for a scheduler.

During a [`pause`](#pause) a pass still observes, queues, audits and retires merged
sessions, and sends no digest, nudge or `limit` resume. The first pass at or after the
end of a pause ends it. Inside `quiet_hours` it sends the orchestrator no digest, urgent
items included, and goes on nudging Leads.

A pass also keeps a Claude orchestrator's cache warm while work is active, with one
fixed line after `keep_warm_after`. With nothing active, in quiet hours or during a
pause it sends one `/compact` instead, and the cache then lapses. Both go only to an
idle orchestrator with an empty composer, and neither counts as a wake.

```bash
./scripts/nogg session dispatch --once
./scripts/nogg session dispatch --dry-run --json
```

**Used by.** An operator or an external scheduler. State, the queue and the
`dispatch.jsonl` audit log live under `.nogging/state/dispatch/`. See
[`session_dispatch`](configuration.md#session_dispatch).

### session inbox

Show the wake queue: the pending items, why delivery is held, the last wakes and the
recent actions from the audit log. During a pause it says so and counts the held items.
It only reads, and works with the dispatcher off. Item text is agent output, cleaned
and labelled as data.

```bash
./scripts/nogg session inbox
./scripts/nogg session inbox --json
```

**Used by.** Every session. The orchestrator reads it when a digest ends in
`Overflow:`.
## loop

**Purpose.** Define recurring work in a repository file, approve its exact
contents on this host, and inspect its schedule, state and run history. The
definitions and prompts are versioned unless `loops_file` points to an ignored
host-local path. Runtime state and approvals always stay under
`.nogging/state/loops/` in the main checkout.

**Common forms.**

```bash
./scripts/nogg loop add dependency-check --every 5d --start 2026-10-28T03:00 \\
  --mode launch --agent codex --tier routine --prompt-file ./dependency-check.md
./scripts/nogg loop list
./scripts/nogg loop show dependency-check
./scripts/nogg loop log dependency-check --limit 20
./scripts/nogg loop pause dependency-check
./scripts/nogg loop resume dependency-check
./scripts/nogg loop run-now dependency-check
./scripts/nogg loop approve dependency-check
./scripts/nogg loop remove dependency-check
./scripts/nogg loop tick
```

**Used by.** Operators and the Orchestration Agent. Mutations are refused in
supervised sessions except the Orchestration Agent; reads are available to all
roles.

**Read more.** [Scheduled loops](scheduled-loops.md).


### loop add

Define a schedule and send or launch action with `--prompt` or `--prompt-file`.
The command validates the prompt, writes the definition, and approves that exact
definition on this host.

### loop list

Show the host status, next slot in local time and UTC, and last recorded outcome.
Use `--json` for the versioned read contract.

### loop show

Show the definition, approval status, next five slots and active run. Use
`--json` for machine-readable output.

### loop log

Show run history newest first. `--limit` bounds the number of events; an absent
or empty history is an empty result. Use `--json` for machine-readable output.

### loop pause

Pause one loop on this host without editing its versioned definition.

### loop resume

Resume one loop on this host and clear its suspended status.

### loop run-now

Run one approved loop immediately through usage and target admission, without
applying its schedule or time window. A busy target is reported as skipped.

### loop approve

Display the mode, target or agent, tier, authority and prompt hash, then approve
the definition currently on disk for this host.

### loop remove

Remove the definition and its prompt while retaining run history.

### loop tick

Evaluate every enabled loop once. The command runs only in the main checkout,
refuses every supervised session, and exits successfully when another tick
holds the scheduler lock.

During a [`pause`](#pause) it logs each due slot of a loop outside `keep_loops` once as
`paused-global`, starts nothing for that loop and writes no state for it, so a loop
paused on its own stays paused. It goes on supervising runs that already started. It
ends a pause at its time first, with the dispatcher on or off.

## pause

**Purpose.** Hold automation while you are away. The orchestrator gets no digest,
running Leads get no nudge or `limit` resume, and loops outside `--keep-loop` do not
run. The queue, the audit log and the retirement of merged sessions go on, nothing is
lost, and when the pause ends what it held reaches the orchestrator as one digest of
at most 1.5 KiB. What does not fit follows in the next wake, and `session inbox` shows it.
A pause stops no session and no timer, and blocks no launch made on purpose: `loop
run-now` and `session launch` still work.

**Common forms.**

```bash
./scripts/nogg pause --until 2026-11-03            # until 00:00 local on that date
./scripts/nogg pause --until 2026-11-03T08:30      # until that local time
./scripts/nogg pause --days 3 --keep-loop morning-report
./scripts/nogg pause --status
./scripts/nogg pause --status --json
```

`--days n` is `n` times 24 hours from now. The end must lie in the future and at most
60 days away, so a forgotten pause ends by itself, at the first `loop tick` or
`session dispatch --once` at or after it. `--keep-loop` may repeat, and each name must
exist in the loops file. A refused end or name writes nothing. A second `pause`
replaces the end and the kept loops and keeps the original start. The state is
`.nogging/state/pause.json` in the main checkout, and a file that cannot be used counts
as not paused and is a `doctor` WARN.

**Used by.** An operator, and the Orchestration Agent when the Product Owner says they
will be away. `pause` is refused in every other supervised session and outside the main
checkout. `--status` only reads and works in every session. `doctor`, `session list`,
`loop list` and `session inbox` show a pause too.

## resume

**Purpose.** End a pause now. If an item appeared or cleared during it, one `resumed`
item is queued with the length of the pause, how many items were seen, how many cleared
on their own and the sessions that finished, and it goes out with the held items as one
digest on the next idle pass. A pause in which nothing happened queues nothing and costs
no wake. With no pause it says so and exits 0.

**Common forms.**

```bash
./scripts/nogg resume
```

**Used by.** The same callers as `pause`, under the same refusals. A loop paused with
`loop pause` stays paused.
