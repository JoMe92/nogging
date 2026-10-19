# orchestration-agent Specification

## Purpose

Defines the always-on orchestration persona, its supervision lifecycle and delegation boundaries within the Nogging operating model.

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

`scripts/nogg orchestrator restart` SHALL terminate the active orchestrator tmux
session cleanly and restart the supervisor service so that the next supervisor
run relaunches the Claude session with the current launch prompt and settings,
resuming the prior transcript. A `--supervisor-only` flag SHALL restart only the
supervisor service, adopting the live tmux session without terminating it.

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

#### Scenario: Operator restarts the orchestrator

- **WHEN** `scripts/nogg orchestrator restart` is invoked
- **THEN** the live orchestrator tmux session is terminated cleanly
- **AND** the systemd supervisor service is stopped and started
- **AND** the next supervisor run starts a new session resuming the prior conversation with the current prompt and settings
- **AND** the session record records exit reason "restarted by operator"

#### Scenario: Supervisor-only restart adopts the live session

- **WHEN** `scripts/nogg orchestrator restart --supervisor-only` is invoked
- **THEN** the systemd supervisor service is restarted without terminating the live tmux session
- **AND** the supervisor adopts the existing tmux session without launching a second agent

### Requirement: Exactly one Orchestration Agent runs at a time

`scripts/nogg orchestrator run` SHALL acquire `.nogging/locks/orchestrator.lock`
and SHALL refuse, naming the holder, while that lock is held. The orchestrator
lock is independent of the planning lock; a `plan` takeover holds both.

The lock SHALL record:

- the holder's process ID, host and creation time;
- the holder's process start time and PID namespace.

A single rule SHALL decide whether the lock is held or stale. `orchestrator
run`, `orchestrator status`, `recover` and `doctor` SHALL all apply it:

- **Verified holder.** The lock is held, and never stale whatever its age, when
  the caller is on the holder's host and in the holder's PID namespace, and
  the holder process is alive with the recorded start time.
- **Legacy lock.** A lock without a recorded start time is held by a verified
  holder when its process is alive and is a Nogging `orchestrator run`.
- **Dead holder.** On the same host and in the same namespace, the lock is
  stale when the holder process is gone, has another start time, or is
  another command. A stale lock is reclaimable without `--force`.
- **Unobservable holder.** When the caller cannot observe the holder's PID
  namespace, the holder is unverifiable and the lock SHALL NOT be reported
  stale. This includes a caller inside the OpenSpec execution sandbox.
- **Another host.** `orchestrator_lock_ttl_seconds` decides staleness only
  when the holder runs on another host.

`recover` SHALL count only a stale lock as needing attention.

#### Scenario: A second orchestrator is refused

- **WHEN** `orchestrator run` is invoked while `orchestrator.lock` is held by a live, verified holder
- **THEN** it exits non-zero and names the holding host and pid
- **AND** it starts no tmux session

#### Scenario: A day-old lock with a live holder is not stale

- **WHEN** the orchestrator lock is older than `orchestrator_lock_ttl_seconds`
- **AND** its holder process is alive with the recorded start time
- **THEN** `recover` and `doctor` report the lock as held, not stale
- **AND** `recover` does not exit non-zero because of it

#### Scenario: A sandboxed caller does not report the lock stale

- **WHEN** a Lead inside the OpenSpec execution sandbox runs `recover`
- **AND** the orchestrator lock's holder lives in the host PID namespace
- **THEN** `recover` reports the holder as unverifiable and not stale

#### Scenario: A dead holder's lock is reclaimable

- **WHEN** the recorded holder process is gone, or its start time differs from the lock
- **THEN** the lock is reported stale
- **AND** `orchestrator run` reclaims it without `--force`

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

### Requirement: The orchestrator directs archiving when doctor reports readiness

When `scripts/specforge doctor` reports a change ready to archive, the
Orchestration Agent SHALL treat that as a signal to direct a planning
session's archive step — either by starting a planning session itself or by
naming the change to one already running — rather than leaving the readiness
note unacted on indefinitely. Directing the archive step this way is
orchestrate-only behavior: the orchestrator still does not perform the
`openspec archive` call itself outside an explicit takeover.

#### Scenario: The orchestrator acts on an archive-readiness note

- **WHEN** the Orchestration Agent reads a `doctor` NOTE reporting a change
  ready to archive
- **THEN** it starts or directs a planning session to perform the archive step
- **AND** it does not call `openspec archive` directly itself outside an
  explicit `/orchestrate takeover plan` instruction

### Requirement: Interactive orchestrator sessions have a documented permission template

Nogging SHALL ship a Claude settings template for interactive Orchestration Agent sessions containing allow rules for the repository's sibling worktree path pattern and `scripts/nogg` commands, and a deny list that includes every command-floor entry. The documentation SHALL state that allow rules do not bypass the auto-mode classifier, that `autoMode` configuration is read only from user settings, and that the operator applies the template manually. The installer SHALL NOT write the template into any settings file. A test SHALL verify the template is valid JSON and that its deny list is a superset of the command floor.

#### Scenario: Floor drift is caught

- **WHEN** a command-floor entry is added that the template's deny list lacks
- **THEN** the template test fails

#### Scenario: Install leaves user settings untouched

- **WHEN** `nogg init` or `nogg update` runs
- **THEN** no user or project settings file gains the template's rules

### Requirement: The orchestrator classifies every launch into a complexity tier

Before every sub-session launch of any role, the Orchestration Agent SHALL take three steps. It SHALL classify the task into one tier of the model-selection table (`routine`, `standard` or `complex`). It SHALL record a one-line reason in the Bead note or operator update. It SHALL launch with `--tier <tier>`. It SHALL take model and effort from the table, not from live research. It SHALL apply the documented escalation rules: when unsure, choose the higher tier, and on a relaunch after a failed or stalled attempt, escalate one tier. It SHALL NOT lower a tier because of quota pressure. A quota denial SHALL be handled by waiting for the limiting reset or by choosing another agent's entry for the same tier. Explicit `--model` or `--effort` overrides SHALL be used only on Product Owner instruction, and SHALL be passed together with the honest `--tier` so attribution stays correct. When the Product Owner's Codex cost policy is in force (Codex defaults to `gpt-6-luna`; `gpt-6.1-sol` only with effort `low` and only for extremely hard tasks), the orchestrator SHALL launch Codex with `--model gpt-6-luna --effort <level>` by default, and with `--model gpt-6.1-sol --effort low` only for such a task. This procedure and these command spellings SHALL be stated in the orchestrator launch prompt, the `/orchestrate` command and the operating model, so a fresh orchestrator session applies it without memory of earlier conversations.

#### Scenario: Fresh orchestrator launches a Lead session

- **WHEN** a newly started orchestrator with no prior conversation launches a Lead session for a Bead
- **THEN** it records a tier with a reason and the launch carries `--tier`, which `session list` shows

#### Scenario: Quota pressure does not downgrade

- **WHEN** a task classified `complex` would exceed an account limit
- **THEN** the orchestrator waits for the reset or uses another agent's `complex` entry, and never launches the task at a lower tier

#### Scenario: Codex cost policy is applied

- **WHEN** a fresh orchestrator launches a Codex Lead for a `complex` task under the Product Owner's Codex policy
- **THEN** the launch carries `--tier complex --model gpt-6-luna --effort <level>`, and the prompt names `--model gpt-6.1-sol --effort low` as the only Sol spelling, reserved for extremely hard tasks
