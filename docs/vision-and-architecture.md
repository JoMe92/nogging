# Vision and architecture

This document states what SpecForge is for, describes the architecture as it is
built today, and records where the implementation deliberately departs from the
concept conversation of 2026-08-31 (`docs/source/konversation-export.md`).

For the day-to-day process see `operating-model.md`; for the data contracts and
the write-boundary enforcement see `architecture.md`.

## Goal

SpecForge lets one person run a spec-driven development loop with AI agents
without an enterprise ALM stack. It keeps three authorities separate and lets a
mechanical process — no LLM, no judgement — keep them consistent:

- **OpenSpec** — what was agreed. Product intent, written only in a deliberate
  planning session.
- **Beads** — what is happening. Executable work items, one per OpenSpec task,
  plus discoveries.
- **Git** — what was implemented. Commits, each tied to a Bead.

The rule is directional: OpenSpec is the source of intent, Beads the source of
progress, Git the source of implementation. Nothing downstream rewrites
something upstream automatically. A closed Bead is *mirrored* into OpenSpec as
evidence; it never edits the agreed spec.

The design target is a Raspberry Pi and a solo Product Owner, so every part is
chosen for low ceremony: file locks instead of merge orchestration, a polling
timer instead of an event bus, native Beads labels instead of a custom metadata
schema, and a boundary enforced by a hook instead of a review policy.

## Origin

The starting point was a 34-section "OpenSpec ↔ Beads Lifecycle" concept with a
five-state change machine, a permanently-running planning agent, and a bespoke
metadata layer. The concept conversation cut that down:

- five change states → three (`open`, `done`, `archived`); acceptance is a flag.
- permanent planning agent → planning and execution are two **session personas**
  that run in parallel, connected only through the shared OpenSpec/Beads state.
- custom metadata → native Beads labels and notes.
- the sync engine is split into a **mechanical part** (close a Bead, mirror its
  state — scriptable) and a **discovery part** (is this finding plan-relevant? —
  stays manual).

SpecForge implements that simplified model. The one part of the concept it
reverses is distribution (see *Concept vs. implementation*).

## Architecture as built

### Two planes

| Plane | Who | Writes | Mechanism |
| --- | --- | --- | --- |
| Semantic | Planning Agent (persona), Product Owner | `openspec/**` | a deliberate planning session holding `.specforge/locks/planning.lock` |
| Mechanical | the sync timer | task checkboxes, `execution-log.md`, `.specforge/state/**` | `scripts/specforge sync`, every 30 s, facts only |

Execution — the Main Worker persona and the specialists it delegates to — writes
only Beads and code, never `openspec/**`.

### The bridge: `scripts/specforge`

A single dependency-light Python script. It contains no LLM call and makes no
product decision. Subcommands:

- `plan-begin` / `plan-end` — acquire and release the planning lock.
- `validate` / `audit` — the invariants in `architecture.md`.
- `materialize <change>` — create one Bead per task, each labelled
  `openspec:change:<id>` and `openspec:task:<id>`. Idempotent.
- `sync` — one reconciliation pass under an exclusive lock: check the task box
  of every closed mapped Bead, append an `execution-log.md` entry with a stable
  event key, commit as `SPECFORGE_WRITER=sync`.
- `discoveries` — list Beads carrying the `discovery` label, blocking first.
- `doctor` — tool availability plus `validate`.

### The write boundary

Invariant 5 — execution agents do not alter `openspec/` — is enforced in depth
by three independent layers: a Claude Code `PreToolUse` guard, a Git
`pre-commit` hook, and a Git `commit-msg` hook. The full mechanism, its
interaction table and its limitations are in `architecture.md`. This is more
than the concept asked for (one hook plus a commit-message rule); the extra
layers cover Bash writes and non–Claude-Code editors.

### Distribution: the installer

`npx github:JoMe92/specforge init` installs the whole structure into a target
git repository in one command; `update` refreshes it; `doctor` reports
readiness. The CLI is a zero-dependency Node program (`bin/`), published from
this repository — no npm-registry release, no build step. It writes files by
class:

| Class | Examples | `init` | `update` |
| --- | --- | --- | --- |
| verbatim | `scripts/specforge`, the hooks, `.agents/skills/**` | overwrite | overwrite |
| scaffold | `openspec/project.md`, `.specforge/config.json` | write if absent | skip |
| merge | `.claude/settings.json`, `.gitignore`, `CLAUDE.md`, `AGENTS.md` | idempotent merge | idempotent merge |
| rendered | `systemd/specforge-sync-<slug>.{service,timer}` | render with the target's path | render |

`init` also runs `bd init`, then ends with a readiness verdict — `SpecForge is
ready` or the list of missing prerequisites. Target-owned content
(`openspec/changes/**`, planning state, the config `name`) is never touched by
`update`.

### Roles

- **Product Owner** — describes outcomes, decides ambiguities, accepts and
  archives.
- **Planning Agent** and **Main Worker** — two personas of the top-level
  session, not subagents. The Planning Agent writes OpenSpec in a locked
  session; the Main Worker claims Beads, delegates, commits, closes.
- **Specialists** — six real subagents (`architect`, `ui-ux-designer`,
  `backend-engineer`, `frontend-engineer`, `code-reviewer`, `test-runner`)
  invoked through the Task tool, each scoped to one claimed Bead. *(Planned —
  see the roadmap.)*
- **Sync timer** — a systemd user timer firing `scripts/specforge sync` every
  30 s. It mirrors facts and makes local commits only; it never pushes, closes
  Beads, or archives.

## Concept vs. implementation

### Followed

| Concept | In the repo |
| --- | --- |
| Two-phase parallel model, personas not a daemon | `operating-model.md`; personas connected only through shared state |
| Mechanical sync, no LLM | `scripts/specforge sync` |
| Three change states, acceptance as a flag | `architecture.md` — `open` / `done` / `archived` |
| Discovery via native Beads labels + notes | `bd list --label discovery`; `scripts/specforge discoveries` |
| Source-of-truth direction | enforced by the write boundary and the mirror-only sync |
| Session lock instead of merge handling | `.specforge/locks/planning.lock` |
| `PreToolUse` hook, exit 2 | `scripts/hooks/pre-tool-use-openspec-guard` (+ two more layers) |
| `commit-msg` rule requiring a work-item token | `scripts/hooks/commit-msg` |
| `execution-log.md` written by the mechanical part | generated in `sync()` |
| Minimal CI invariants | `.github/workflows/specforge-validate.yml` |
| Update mechanism planned from the start | `update` command + `specforge_version` tracking |
| `doctor` health check | `scripts/specforge doctor` + `bin/cli.js doctor` + readiness verdict |
| Toolkit version scheme | `package.json` version, pinnable as `#v1.0.0` |

### Deliberately changed

| Concept | As built | Why |
| --- | --- | --- |
| Distribution: a central **pipx** Python package; the engine is **not** copied into the target; the target stays free of the engine's language | a **zero-dependency Node CLI** that **copies** `scripts/specforge` (Python), the hooks (bash) and `.agents/skills` **into** the target | Product Owner chose `npx github:` over the existing `gh` credential: no registry publish, no pipx runtime to manage, the target is self-contained. Trade-off: target repos now carry the bridge and need `python3`. |
| `.agentic/config.yml`; `.agentic/systemd/sync-engine.service` via Pixi | `.specforge/config.json`; `systemd/specforge-sync-<slug>.{service,timer}` rendered per repo, no Pixi | one namespace under `.specforge/`; a per-repo slug lets several target repos run timers side by side; no Pixi dependency |
| `[BEAD-XXX]` commit token | `[SPEC-xxx]` — the real Bead-ID shape | matches the actual Bead prefix; a literal `[BEAD-XXX]` placeholder is explicitly rejected |
| Long-lived sync **daemon** with a PID file, `SIGUSR1` "sync-now", and a 5-minute poll | a systemd **oneshot** timer every 30 s, no resident process | no daemon lifecycle to supervise; 30 s is cheap; "sync-now" becomes a direct `sync` run |
| Repo name `agentic-workflow-toolkit` | `specforge` | rename |

### Not yet built (on the roadmap)

| Concept | Roadmap change |
| --- | --- |
| transient/permanent sync-failure classification, JSONL log with rotation; closed-Bead reconciliation; enriched `execution-log.md` (Bead note + commit SHA) | `reliable-beads-sync` |
| `/plan`, `/discovery-review`, `/sync-now` slash commands | `planning-and-discovery-commands` |
| the six specialist `.claude/agents/*.md` and the Lead Agent delegation model | `specialist-agents-and-skills` |
| a checked branch-naming convention and a CI invariant over pull-request commits | `enforce-conventional-branching` |
| remotely observable / stoppable agent sessions on the Pi | `remote-observable-claude-sessions` |
| one reproducible end-to-end run with a human sign-off | `end-to-end-acceptance` |

A defect found while building the installer is also tracked: `bd list` omits
closed issues by default, so both `sync` and `materialize` miss closed mapped
Beads (`reliable-beads-sync` carries the fix).

### Concept open points — status

| Open point (concept §"Offene Punkte") | Status |
| --- | --- |
| Full agent prompts and slash commands | planned — `planning-and-discovery-commands`, `specialist-agents-and-skills` |
| `execution-log.md` as a fixed part of `sync_task()` | done; note + SHA enrichment planned in `reliable-beads-sync` |
| Concrete systemd deployment | done — the installer renders the unit and prints the `systemctl --user enable` line |
| `.agentic/config.yml` format | done as `.specforge/config.json` |
| `doctor` check logic | done |
| Toolkit version scheme | done — `v1.0.0` tagged |

## Status

`v1.0.0` is the installer plus the base structure: a target repo can run
`npx github:JoMe92/specforge init` and reach a ready-to-plan state. The six
roadmap changes above are planned in `openspec/changes/` and materialised as
Beads; they harden the sync, add the operator commands, and bring the specialist
execution model online.

### Roadmap execution order

The changes are materialised as Beads with cross-change dependencies wired via
`bd dep add`. Work them one change per branch (`<type>/<change-name>`), in this
order:

1. **`reliable-beads-sync`** — first. Fixes the `bd list` closed-issue defect, so
   `sync` and `materialize` stop missing closed mapped Beads; establishes the
   enriched `execution-log.md`, the acknowledgement ledger, and classified sync
   failures that later changes build on.
2. **`enforce-conventional-branching`** — independent; can run in parallel with 1.
   After it lands, the CI `invariants` job checks every pull request.
3. **`planning-and-discovery-commands`** — after 1 (`/discovery-review` uses the
   acknowledgement ledger from `TASK-SYNC-006`).
4. **`specialist-agents-and-skills`** — after 3 (the delegation section in
   `CLAUDE.md` references `/plan`).
5. **`remote-observable-claude-sessions`** — independent; slot in once 1–4 free
   up attention. Larger surface (tmux, systemd, a restricted launch profile).
6. **`end-to-end-acceptance`** — last. Depends on all of the above; its runbook
   exercises the whole chain and its assertions are written against
   post-`reliable-beads-sync` behaviour.

Within a change, work the tasks in `tasks.md` order. `photo-import-filesystem`
is a concept walkthrough, not scheduled work — its Beads are deferred.
