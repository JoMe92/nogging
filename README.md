![Nogging](docs/brand/nogging-banner.png)

# Nogging

[![Nogging validation](https://github.com/JoMe92/nogging/actions/workflows/nogging-validate.yml/badge.svg?branch=main)](https://github.com/JoMe92/nogging/actions/workflows/nogging-validate.yml)

**Structure for a team of agents.**

Nogging gives coding agents (Claude Code, Codex, Pi, Antigravity) a team structure with a defined role and write boundary for each. A Planning Agent writes the approved plan in OpenSpec, a Lead Agent executes it as Beads tasks with Git evidence, and a sync mirrors that evidence back into the plan. The command and installed state are named `nogg`.

> Nogging is a **public release**. Read the [safety warning](#safety-warning)
> and the [security and threat model](docs/security-model.md) before you enable
> `--full-access` or background services.

## Quick Guide

From nothing to a closed first Bead. Each step links to its details below.

1. Install the toolchain and Nogging on a fresh machine, pinned to a release: `curl -fsSL https://raw.githubusercontent.com/JoMe92/nogging/v3.0.0/scripts/bootstrap | bash` ([details](#install)).
2. Check that the machine is ready: `./scripts/nogg doctor` ([details](#install)).
3. Plan a change with the Planning Agent: `/plan` in Claude Code ([details](#plan-a-change)).
4. Find the work the plan created: `bd ready` ([details](#launch-a-lead)).
5. Launch a Lead Agent on one Bead: `./scripts/nogg session launch --role lead --bead <id>` ([details](#launch-a-lead)).
6. Watch it work: `./scripts/nogg session list`, then `./scripts/nogg session log <name> --follow` ([details](#watch-and-steer-sessions)).
7. Review the pull request, then mirror the evidence back: `./scripts/nogg sync --now` ([details](#close-out)).
8. Triage what the Lead discovered: `/discovery-review` ([details](#close-out)).

![From zero to a running repo: install the required and optional components, install Nogging into the repository with an exact pinned tag, verify the machine with nogg doctor, optionally enable background sync, then work the plan / materialize / execute / mirror loop](docs/brand/nogging-quick-start.png)

## Install

### Fresh machine (scripts/bootstrap)

Starting from a completely fresh machine? One pinned command provisions the
whole toolchain (Node via `nvm`, the agent CLIs, `bd`, Dolt, `git`/`tmux`/`gh`)
and then runs `init` for you; on a terminal it offers a short wizard:

```bash
curl -fsSL https://raw.githubusercontent.com/JoMe92/nogging/v3.0.0/scripts/bootstrap | bash
```

Always pin a tagged release in that URL, never `main`/`develop`. Add
`--repo <path>` to target a different (or brand-new) repository and
`--with-pi` to also install the optional Pi coding agent CLI. It is safe to
re-run: each step checks what's already installed first and only provisions
what's missing or out of range. See
[docs/installation.md](docs/installation.md#fresh-machine-scriptsbootstrap)
for the full flag reference.

### Existing repository (npx init)

Already have Node 18+ and the rest of the toolchain? Start in a new or
existing Git repository instead. The command is pinned because the initial
distribution is GitHub-only:

```bash
npx github:JoMe92/nogging#v3.0.0 init --no-systemd
./scripts/nogg doctor
./scripts/nogg validate
```

`init` creates the Beads tracker by default and prints a readiness verdict. It
does not require a website or Agent Console. Remove `--no-systemd` only after
reviewing the [safety warning](#safety-warning). The unscoped npm name `nogg`
belongs to another project, so this package is private and is installed from
a GitHub tag only.

`init` copies the tool files verbatim, writes an OpenSpec scaffold only where
one is missing, and merges the guard, `.gitignore`, `CLAUDE.md` and
`AGENTS.md` idempotently. It never touches `openspec/changes/`, `.beads/`, or
your `package.json`.

- Refresh a repository with `npx github:JoMe92/nogging#v3.0.0 update`.
- Remove the managed payload with `npx github:JoMe92/nogging#v3.0.0 remove`.

The full reference is in [docs/installation.md](docs/installation.md).

## Use it day to day

### Plan a change

In Claude Code, run `/plan`. Without it, start the supervised planner, which
gets its own worktree, stays idle until kickoff and takes the canonical planning
lock itself:

```bash
./scripts/nogg session launch --role planning --planning-id <planning-id> --description <description>
```

The manual sequence is the same flow, with both ids in kebab-case:

```bash
./scripts/nogg worktree plan <planning-id> <description>
cd <printed planning worktree path>
./scripts/nogg plan-begin
# Author the OpenSpec change, with stable TASK-... IDs in tasks.md.
./scripts/nogg validate
NOGGING_WRITER=planning git commit -m "docs(openspec): <summary>"  # commit as the planning writer before materialize
./scripts/nogg materialize <change-name>
bd dep add <blocked-id> <blocker-id>   # wire the dependencies explicitly
./scripts/nogg plan-end   # from the planning worktree, in the owning session
cd <main checkout>
./scripts/nogg worktree cleanup <record>   # last command, surviving canonical checkout
# If cleanup refuses: ./scripts/nogg session stop <name>, then
# ./scripts/nogg worktree cleanup <record> from the canonical checkout.
```

`plan-end` always precedes worktree retirement.

### Launch a Lead

`bd ready` lists the unblocked Beads and `bd show <id>` shows one. Launch a
Lead on a Bead with restricted authority:

```bash
./scripts/nogg session launch --role lead --bead <id>
```

Full access removes that restriction. Read the
[security and threat model](docs/security-model.md) first; only then add
`--full-access` on a host and repository you trust:

```bash
./scripts/nogg session launch --role lead --bead <id> --full-access
```

### Watch and steer sessions

- `./scripts/nogg session list` shows the running sessions.
- `./scripts/nogg session log <name> --follow` follows a session's output.
- `./scripts/nogg session attach <name> --read-only` looks inside without typing.
- `./scripts/nogg session watch` reports progress and stalls across sessions.
- `./scripts/nogg session send <name> "<message>"` and `session nudge <name>` steer a session.
- `./scripts/nogg session stop <name>` ends it.

An optional always-on Orchestration Agent can drive these for you; see
[Orchestration](docs/operating-model.md#orchestration).

### Close out

The Lead commits with the `[<ID>]` token in the subject, runs `bd close <id>`
and `./scripts/nogg task-done <id>`, and leaves the evidence note on the Bead.
You review the pull request, run `./scripts/nogg sync --now` (or rely on the
timer, enabled with `systemctl --user enable --now nogg-sync.timer`), triage
discoveries with `/discovery-review`, and archive the change when
`./scripts/nogg doctor` reports it ready. Acceptance is a signed human report.

![Working with it day to day: a worked example that reads OpenSpec and Beads, plans a change in a locked planning worktree, implements one Bead in a supervised session, and lets the sync timer mirror the closed work back into OpenSpec as evidence](docs/brand/nogging-daily-workflow.png)

## Safety warning

Nogging installs repository instructions and Git hooks, can run a persistent
user service, and can launch coding agents with filesystem, network, and shell
access. Protection differs across Claude Code, Codex, and Pi, so review what is
installed, protect credentials, and start with restricted authority.

Read the [security and threat model](docs/security-model.md),
[the operating model](docs/operating-model.md),
[session guidance](docs/running-work-in-sessions.md), and
[failure recovery](docs/failure-recovery.md) before you enable full access or
always-on operation.

## Project status and audience

Nogging is a **public release**. Its core workflow and Linux installation path
are exercised in CI. Keep target repositories where agents run with full access
private, and read the [safety warning](#safety-warning) before enabling
`--full-access` or background services.

Nogging is for teams and maintainers who want autonomous coding agents to work
from approved specifications with durable task ownership and auditable Git
evidence. It is not an agent runtime, hosted service, or replacement for your
existing Git repository, OpenSpec installation, or Beads tracker.

## Supported environments

- **Platform:** Linux is the supported host. Bash, Git, Python, Node.js,
  OpenSpec, Beads, and Dolt are required for the complete workflow.
- **Agents:** payloads and guidance are included for Claude Code, Codex, and
  Pi. Their permission and sandbox guarantees differ.
- **Optional host features:** systemd provides background sync and tmux
  or herdr provides supervised sessions. Use `--no-systemd` when neither is wanted.
- **Other systems:** macOS, Windows, other service managers, and unlisted agent
  versions are not currently claimed as supported.

See the [compatibility policy and matrix](docs/compatibility.md) for minimum
versions, supported combinations, and evidence. `./scripts/nogg doctor` checks
the current machine against the required tool set.

## Concepts

OpenSpec owns approved product intent, Beads owns executable work, and Git owns
the implementation. A deterministic sync process mirrors execution evidence
back into OpenSpec; it never makes product decisions.

### The two phases

1. **Planning:** a Product Owner and Planning Agent create or amend an OpenSpec
   change, validate it, and materialize its stable task IDs as Beads.
2. **Execution:** a Main Worker claims ready Beads, implements and validates
   them, commits code, records discoveries, and closes the Bead.

The phases may run at the same time. Planning is session-based, not a resident
LLM process. The Main Worker and specialist agents must never edit `openspec/`.

### Roles

The **Product Owner** decides what is built. The **Planning Agent** turns that
into an OpenSpec change. The **Lead Agent** (Main Worker) executes the Beads
tasks and may delegate to six specialists (architect, UI/UX designer, backend
and frontend engineers, code reviewer, test runner). The optional
**Orchestration Agent** drives Planning and Lead sessions from above.

### Non-negotiable boundaries

| Authority | System | May write |
| --- | --- | --- |
| Intent, requirements, decomposition | OpenSpec | Product Owner / Planning Agent during a planning session |
| Claims, dependencies, status, discoveries | Beads | Main Worker and specialists |
| Code and tests | Git worktree | Main Worker and specialists |
| Execution mirror | OpenSpec execution log | Nogging sync process only |

`open → done → archived` is the entire change lifecycle. Product acceptance is
an explicit `accepted: true` record, not another workflow state: a change is not
accepted until a signed acceptance report has been committed, produced by
running [docs/acceptance.md](docs/acceptance.md) and filled in from
[docs/acceptance-report-template.md](docs/acceptance-report-template.md). The
mechanical subset of that runbook runs unattended as the `acceptance` CI job.

![Who talks to whom: Product Owner, the Planning Agent and Main Worker personas, six advisory specialists, and the sync timer, connected through OpenSpec, Beads and Git](docs/brand/nogging-communication-model.png)

![What runs on top of what: four callers — the Product Owner, an agent session, the sync timer, and Git hooks — reach the single scripts/nogg CLI, which shells out to OpenSpec, Beads, Git, Dolt, tmux, herdr, and systemd and stores state in openspec/, .beads/, .git/, and .nogging/](docs/brand/nogging-tool-map.png)

Go deeper in [Vision and architecture](docs/vision-and-architecture.md), the
[operating model](docs/operating-model.md) and the
[architecture reference](docs/architecture.md).

## Documentation

Full index, grouped by concepts / using Nogging / releasing and maintaining:
[docs/README.md](docs/README.md).

| Need | Guide |
| --- | --- |
| Concepts and architecture | [Vision and architecture](docs/vision-and-architecture.md) |
| Data contracts and safety layers | [Architecture](docs/architecture.md) |
| Install, update, and remove | [Installation](docs/installation.md) |
| Roles and delivery workflow | [Operating model](docs/operating-model.md) |
| Isolated Git worktrees | [Worktree workflow](docs/worktree-workflow.md) |
| Supervised agent sessions | [Running work in sessions](docs/running-work-in-sessions.md) |
| Security boundaries and safe disable | [Security and threat model](docs/security-model.md) |
| Supported versions and platforms | [Compatibility matrix](docs/compatibility.md) |
| Codex integration | [Using Nogging with Codex](docs/using-with-codex.md) |
| Pi integration | [Using Nogging with Pi](docs/using-with-pi.md) |
| Experimental Antigravity integration | [Using Nogging with Antigravity](docs/using-with-antigravity.md) |
| Interrupted-run recovery | [Failure recovery](docs/failure-recovery.md) |
| Acceptance procedure | [Acceptance runbook](docs/acceptance.md) |
| Contributions and conduct | [Contributing](CONTRIBUTING.md) and [Code of Conduct](CODE_OF_CONDUCT.md) |
| Vulnerability reporting | [Security policy](SECURITY.md) |

## Developing Nogging

Clone the repository, run `./scripts/install-hooks`, and run the suite with
`scripts/test` (also `npm test`). The CI job reference is in
[CONTRIBUTING.md](CONTRIBUTING.md#tests-and-ci); maintainers cutting a release
follow [docs/releasing.md](docs/releasing.md). The badge at the top of this file
tracks the `main` branch.

## Inspiration and related projects

Nogging is conceptually inspired by
[Gas Town](https://github.com/steveyegge/gastown), but it is an independent
implementation and is not affiliated with or endorsed by the Gas Town or Beads
maintainers. [Beads](https://github.com/gastownhall/beads) is the only Gas Town
ecosystem component currently adopted; Nogging does not include Gas Town
runtime components.

[Agent Console](https://github.com/JoMe92/agent-console) is an optional sibling
project for orchestration and UI. Nogging works without it.
