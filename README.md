# SpecForge

SpecForge is a lean, local-first operating model for agentic software delivery.
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
cd /path/to/specforge
git switch develop
./scripts/install-hooks
./scripts/specforge doctor
./scripts/specforge plan-begin
# Plan with OpenSpec, then add stable TASK-... IDs to tasks.md.
./scripts/specforge validate
./scripts/specforge materialize photo-import-filesystem
./scripts/specforge plan-end
./scripts/specforge sync
```

The timer is installed with `systemctl --user enable --now specforge-sync.timer`.
See [docs/vision-and-architecture.md](docs/vision-and-architecture.md) for the
goal and the design, [docs/operating-model.md](docs/operating-model.md) for the
process, and [docs/walkthrough-photo-import.md](docs/walkthrough-photo-import.md)
for a worked example.

## Install into another repo

```bash
cd /path/to/your-repo
npx github:JoMe92/specforge init      # then: update, doctor
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
| Execution mirror | OpenSpec execution log | SpecForge sync process only |

`open → done → archived` is the entire change lifecycle. Product acceptance is
an explicit `accepted: true` record, not another workflow state.

## Tests

```bash
scripts/test   # runs every scripts/**/*.test.sh; also `npm test`
```

The runner is language-neutral and offline: bash and coreutils only, no Node,
no network, and no running Beads/Dolt server (tests that need `bd` stub it). CI
runs it on every push and pull request. It covers the `commit-msg` boundary
hook — Beads ID accepted, missing ID rejected, and the `planning`/`sync`
`SPECFORGE_WRITER` exemptions.
