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
./scripts/nogg usage install-statusline
```

**Used by.** The operator and the Orchestration Agent.

**Read more.** [Usage limits](usage-limits.md) and the
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
`ok: <command> (<seconds> s; log <path>)`. On failure it prints a `FAIL (exit
<code>)` line and the last lines of the log (40 unless `--tail N` says
otherwise), then exits with the command's exit code. A death by signal N exits
128+N, and a command that is not found exits 127. The log is a new
`nogg-run-quiet.*.log` file in `$TMPDIR` unless `--log PATH` names one. The
command runs without a shell, so wrap a pipeline in `bash -c '...'`. SIGINT and
SIGTERM are passed on to the command. The `--` before the command is required.
A command the Nogging command floor denies (`sudo`, `rm -rf`, `dd`, `mkfs`,
`shutdown`, `reboot`) is refused with exit 2, so the wrapper never lifts it.

**Common forms.**

```bash
./scripts/nogg run-quiet -- scripts/test
./scripts/nogg run-quiet --tail 80 --log /tmp/build.log -- npm run build
```

**Used by.** A Lead Agent or specialist that runs a long command. Waiting is one
blocking call, so the agent never polls the running command. A passing suite
leaves one line in the context, not its whole output.

**Read more.** [Operating model](operating-model.md).

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

Allocate an implementation worktree for a Bead that is already claimed.

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

Append a structured event to the calling session's own event file. Agent hooks
call it; it only works inside a launched session.

```bash
./scripts/nogg session emit <event>
```

**Used by.** Agent hooks, not people.
