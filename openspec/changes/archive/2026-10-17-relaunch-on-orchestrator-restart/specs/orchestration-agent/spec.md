## MODIFIED Requirements

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
