# Vision and architecture

This page states what Nogging is for and describes the architecture as it is
built today. It is for anyone deciding whether the model fits them, and for
contributors who want the big picture before the details.

For the day-to-day process see [Operating model](operating-model.md); for the
data contracts and the write-boundary enforcement see
[Architecture](architecture.md).

## Goal

Nogging lets one person run a spec-driven development loop with AI agents
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

Nogging implements that simplified model. The one part of the concept it
reverses is distribution (see *Concept vs. implementation*).

## Architecture as built

### Two planes

| Plane | Who | Writes | Mechanism |
| --- | --- | --- | --- |
| Semantic | Planning Agent (persona), Product Owner | `openspec/**` | a deliberate planning session holding `.nogging/locks/planning.lock` |
| Mechanical | the sync timer | task checkboxes, `execution-log.md`, `.nogging/state/**` | `scripts/nogg sync`, every 30 s, facts only |

Execution — the Main Worker persona and the specialists it delegates to — writes
only Beads and code, never `openspec/**`.

### The bridge: `scripts/nogg`

A single dependency-light Python script. It contains no LLM call and makes no
product decision. Subcommands:

- `plan-begin` / `plan-end` — acquire and release the planning lock.
- `validate` / `audit` — the invariants in [Architecture](architecture.md).
- `materialize <change>` — create one Bead per task, each labelled
  `openspec:change:<id>` and `openspec:task:<id>`. Idempotent.
- `sync` — one reconciliation pass under an exclusive lock: check the task box
  of every closed mapped Bead, append an `execution-log.md` entry with a stable
  event key, commit as `NOGGING_WRITER=sync`.
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

`npx github:JoMe92/nogging#<tag> init` installs the whole structure into a target
git repository in one command; `update` refreshes it; `doctor` reports
readiness. The CLI is a zero-dependency Node program (`bin/`), published from
this repository — no npm-registry release, no build step. It writes files by
class:

| Class | Examples | `init` | `update` |
| --- | --- | --- | --- |
| verbatim | `scripts/nogg`, the hooks, `.agents/skills/**` | overwrite | overwrite |
| scaffold | `openspec/project.md`, `.nogging/config.json` | write if absent | skip |
| merge | `.claude/settings.json`, `.gitignore`, `CLAUDE.md`, `AGENTS.md` | idempotent merge | idempotent merge |
| rendered | `systemd/nogg-sync-<slug>.{service,timer}` | render with the target's path | render |

`init` also runs `bd init`, then ends with a readiness verdict — `Nogging is
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
  invoked through the Task tool, each scoped to one claimed Bead.
- **Sync timer** — a systemd user timer firing `scripts/nogg sync` every
  30 s. It mirrors facts and makes local commits only; it never pushes, closes
  Beads, or archives.

## Concept vs. implementation

### Followed

| Concept | In the repo |
| --- | --- |
| Two-phase parallel model, personas not a daemon | [Operating model](operating-model.md); personas connected only through shared state |
| Mechanical sync, no LLM | `scripts/nogg sync` |
| Three change states, acceptance as a flag | [Architecture](architecture.md) — `open` / `done` / `archived` |
| Discovery via native Beads labels + notes | `bd list --label discovery`; `scripts/nogg discoveries` |
| Source-of-truth direction | enforced by the write boundary and the mirror-only sync |
| Session lock instead of merge handling | `.nogging/locks/planning.lock` |
| `PreToolUse` hook, exit 2 | `scripts/hooks/pre-tool-use-openspec-guard` (+ two more layers) |
| `commit-msg` rule requiring a work-item token | `scripts/hooks/commit-msg` |
| `execution-log.md` written by the mechanical part | generated in `sync()` |
| Minimal CI invariants | `.github/workflows/nogging-validate.yml` (the *Nogging validation* workflow) |
| Update mechanism planned from the start | `update` command + `nogging_version` tracking |
| `doctor` health check | `scripts/nogg doctor` + `bin/cli.js doctor` + readiness verdict |
| Toolkit version scheme | `package.json` version, pinnable as `#<tag>` |

### Deliberately changed

| Concept | As built | Why |
| --- | --- | --- |
| Distribution: a central **pipx** Python package; the engine is **not** copied into the target; the target stays free of the engine's language | a **zero-dependency Node CLI** that **copies** `scripts/nogg` (Python), the hooks (bash) and `.agents/skills` **into** the target | Product Owner chose `npx github:` over the existing `gh` credential: no registry publish, no pipx runtime to manage, the target is self-contained. Trade-off: target repos now carry the bridge and need `python3`. |
| `.agentic/config.yml`; `.agentic/systemd/sync-engine.service` via Pixi | `.nogging/config.json`; `systemd/nogg-sync-<slug>.{service,timer}` rendered per repo, no Pixi | one namespace under `.nogging/`; a per-repo slug lets several target repos run timers side by side; no Pixi dependency |
| `[BEAD-XXX]` commit token | `[SPEC-xxx]` — the real Bead-ID shape | matches the actual Bead prefix; a literal `[BEAD-XXX]` placeholder is explicitly rejected |
| Long-lived sync **daemon** with a PID file, `SIGUSR1` "sync-now", and a 5-minute poll | a systemd **oneshot** timer every 30 s, no resident process | no daemon lifecycle to supervise; 30 s is cheap; "sync-now" becomes a direct `sync` run |
| Repo name `agentic-workflow-toolkit` | `nogg` | rename |

## Status

The installer and the base structure are in place: a target repository can run
`npx github:JoMe92/nogging#<tag> init` and reach a ready-to-plan state. On top
of that, Nogging ships the operator commands (`/plan`, `/discovery-review`,
`/sync-now`, `/orchestrate`), the six specialist agents and the Lead Agent
delegation model, supervised and remotely observable agent sessions, isolated
worktrees, the Orchestration Agent, and a reproducible acceptance procedure
([Acceptance](acceptance.md)).

Nogging supports Linux hosts only. Antigravity sessions and the herdr terminal
backend are experimental. Open limitations and recovery recipes are in
[Failure recovery](failure-recovery.md) and the [FAQ](faq.md).
