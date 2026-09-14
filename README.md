# Nogging

Nogging is a lean, local-first operating model for agentic
software delivery. The compatible command and installed state remain named
`nogg`.
OpenSpec owns approved product intent, Beads owns executable work, and Git owns
the implementation. A deterministic sync process mirrors execution evidence
back into OpenSpec; it never makes product decisions.

## The two phases

1. **Planning:** a Product Owner and Planning Agent create or amend an OpenSpec
   change, validate it, and materialize its stable task IDs as Beads.
2. **Execution:** a Main Worker claims ready Beads, implements and validates
   them, commits code, records discoveries, and closes the Bead.

The phases may run at the same time. Planning is session-based, not a resident
LLM process. The Main Worker and specialist agents must never edit `openspec/`.

```text
Product Owner + Planning Agent ──writes──> OpenSpec ──materializes──> Beads
                                                               │
Main Worker + specialists ──implement/validate/close──────────┘
                                                               │
Sync timer ──mechanically mirrors status and evidence──> execution-log.md
```

## Quick start

```bash
cd /path/to/nogging
git switch develop
./scripts/install-hooks
./scripts/nogg doctor
./scripts/nogg plan-begin
# Plan with OpenSpec, then add stable TASK-... IDs to tasks.md.
./scripts/nogg validate
./scripts/nogg materialize <change-name>
./scripts/nogg plan-end
./scripts/nogg sync
```

The timer is installed with `systemctl --user enable --now nogg-sync.timer`.
See [docs/vision-and-architecture.md](docs/vision-and-architecture.md) for the
goal and the design, [docs/operating-model.md](docs/operating-model.md) for the
process, [docs/running-work-in-sessions.md](docs/running-work-in-sessions.md) for
running work in supervised host sessions, and
[docs/acceptance.md](docs/acceptance.md) for the end-to-end acceptance runbook.

## Install into another repo

The first public distribution is GitHub-only. The unscoped npm name
`nogg` belongs to another project, so this package is marked private and
must not be published to the npm registry. Install an exact Agentsembli
Nogging GitHub tag instead:

```bash
cd /path/to/your-repo
npx github:JoMe92/nogging#v1.6.0 init      # then: update, doctor
```

`init` copies the tool files verbatim, writes an OpenSpec scaffold only where one
is missing, merges the `PreToolUse` guard / `.gitignore` / `CLAUDE.md` /
`AGENTS.md` idempotently, and renders a per-repo systemd sync unit. It never
touches `openspec/changes/`, `.beads/`, or your `package.json`. Full details in
[docs/installation.md](docs/installation.md).

## Non-negotiable boundaries

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

## Tests

```bash
scripts/test   # runs every scripts/**/*.test.sh; also `npm test`
```

The runner is language-neutral and offline: bash and coreutils only, no Node,
no network, and no running Beads/Dolt server (tests that need `bd` stub it). CI
runs it on every push and pull request. It covers the `commit-msg` boundary
hook — Beads ID accepted, missing ID rejected, and the `planning`/`sync`
`NOGGING_WRITER` exemptions.
