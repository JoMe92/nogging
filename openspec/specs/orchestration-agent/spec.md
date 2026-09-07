# orchestration-agent Specification

## Purpose
TBD - created by archiving change orchestration-agent. Update Purpose after archive.

## Requirements

### Requirement: The Orchestration Agent is a third persona above Planning and the Main Worker

SpecForge SHALL define an **Orchestration Agent** persona that sits above the
Planning Agent and the Main Worker (Lead Agent). Its purpose is to drive the
delivery loop: read the shared state (Beads, OpenSpec, session records and
logs, `git`) and decide what to plan or execute next, then launch, steer and
stop Planning and Lead sessions through `scripts/specforge`. The role hierarchy
SHALL be Product Owner → Orchestration Agent → {Planning Agent, Lead Agent} →
Specialists, and `docs/operating-model.md` SHALL state it.

#### Scenario: The orchestrator drives a sub-session

- **WHEN** the Orchestration Agent decides a change should be executed
- **THEN** it starts a Lead session with `scripts/specforge session launch` and steers it through the session's log and `attach`
- **AND** it does not perform the Lead session's Bead work itself

#### Scenario: The hierarchy is written down

- **WHEN** `docs/operating-model.md` is read
- **THEN** it lists the Orchestration Agent above the Planning Agent and the Main Worker

### Requirement: The orchestrator's default scope is orchestrate-only

By default the Orchestration Agent SHALL NOT write any file under `openspec/`
and SHALL NOT edit implementation code. Its actions are limited to reading
state and running `scripts/specforge`, `bd`, `git` (read and local
integration), and the workflow commands. The orchestrator prompt
(`.specforge/launch-prompts/orchestrator.md`) SHALL state this default plainly.

#### Scenario: The orchestrator does not author a spec by default

- **WHEN** the Orchestration Agent identifies a needed spec change and has received no takeover instruction
- **THEN** it starts or directs a planning session to make the change
- **AND** it does not edit `openspec/` itself

### Requirement: The orchestrator performs planning or code work only under an explicit takeover instruction

The Orchestration Agent SHALL take over a planning or a code task directly only
when the operator gives an explicit in-session instruction of the form
`/orchestrate takeover {plan|code} <description>`. A takeover SHALL be scoped
to the one described task, after which the orchestrator returns to
orchestrate-only.

- A `plan` takeover SHALL follow the full planning sequence
  (`plan-begin` … author … `validate` … commit with a Conventional subject and
  a `SpecForge-Writer: planning` trailer … `materialize` … `plan-end`).
- A `code` takeover SHALL claim the named Bead, implement, validate, commit
  with the `[<bead-id>]` token, write the evidence note, and close the Bead.

#### Scenario: A plan takeover commits as the planning writer

- **WHEN** the operator instructs `/orchestrate takeover plan …` and the orchestrator authors an `openspec/` change
- **THEN** the commit carries a `SpecForge-Writer: planning` trailer
- **AND** the CI `invariants` job accepts it

#### Scenario: No takeover means no direct write

- **WHEN** the orchestrator has been given no `/orchestrate takeover` instruction
- **THEN** it makes no commit that touches `openspec/` and claims no Bead

### Requirement: The orchestrator runs always-on and recovers itself

SpecForge SHALL provide a way to run the Orchestration Agent continuously so
that it survives a crash of its own supervisor and a reboot of the delivery
host, and resumes its prior conversation rather than starting cold. A rendered
systemd user service SHALL run `scripts/specforge orchestrator run`, an
idempotent supervisor that keeps a single orchestrator tmux session alive and
uses `claude --continue` when a prior conversation exists for the working
directory. The launched session SHALL register with Remote Control so it is
reachable without SSH.

#### Scenario: The orchestrator returns after a crash

- **WHEN** the `orchestrator run` supervisor process exits unexpectedly while the service is enabled
- **THEN** systemd restarts it
- **AND** the next run adopts the still-live tmux session or resumes the prior conversation

#### Scenario: The orchestrator returns after a reboot

- **WHEN** the delivery host reboots and user lingering is enabled
- **THEN** the orchestrator service starts without an interactive login
- **AND** the session resumes its prior conversation

#### Scenario: The orchestrator is reachable from a phone

- **WHEN** the orchestrator session is running
- **THEN** it appears as a Remote Control session that can be read and typed into without SSH

### Requirement: Exactly one Orchestration Agent runs at a time

`scripts/specforge orchestrator run` SHALL acquire `.specforge/locks/orchestrator.lock`
(the same JSON shape and staleness rule as the planning lock) and SHALL refuse,
naming the holder, when a fresh lock is held by a live process. The
orchestrator lock is independent of the planning lock; a `plan` takeover holds
both.

#### Scenario: A second orchestrator is refused

- **WHEN** `orchestrator run` is invoked while a fresh `orchestrator.lock` is held by a live process
- **THEN** it exits non-zero and names the holding host and pid
- **AND** it starts no tmux session

### Requirement: The orchestrator does not accept changes

The Orchestration Agent SHALL NOT complete the `Signed-off-by:` line of an
acceptance report. Acceptance remains an explicit act of the Product Owner. The
orchestrator MAY run the mechanical acceptance steps and drive the
agent-driven ones through sub-sessions.

#### Scenario: The orchestrator stops at sign-off

- **WHEN** an acceptance run the orchestrator drove is otherwise complete
- **THEN** the acceptance report is left with its `Signed-off-by:` line blank for the Product Owner

### Requirement: The Orchestration Agent is a Claude Code persona in this version

The Orchestration Agent SHALL be provided for Claude Code only. `session
launch --role orchestrator` and the `orchestrator` profile SHALL NOT ship a
Codex or Pi variant in this version; a Codex/Pi orchestrator is a recorded
follow-up.

#### Scenario: No Codex/Pi orchestrator profile ships

- **WHEN** the installed `.specforge/launch-profiles/` directory is inspected
- **THEN** there is an `orchestrator.json` and no `orchestrator.codex.toml` or `orchestrator.pi.toml`
