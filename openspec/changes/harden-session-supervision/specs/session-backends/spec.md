## MODIFIED Requirements

### Requirement: The tmux backend preserves existing behaviour

Moving tmux behind the seam SHALL NOT change any observable tmux behaviour,
except for the shared-server stop rule below and the sandbox start rule in
*The shared tmux server is started only outside the OpenSpec sandbox*. The
following SHALL all stay as before for a caller outside the sandbox:

- the dedicated socket;
- `new-session` with environment;
- the `pipe-pane` log;
- the `display-message` PID;
- the key sequences, including Claude's double Enter;
- `capture-pane` with and without attributes;
- `kill-session`;
- `attach` with `-r`.

The dedicated tmux server is shared by every checkout of the repository and
by the Orchestration Agent. Cleanup SHALL stop it only when the server's own
session listing succeeds and reports no session. Retiring the current
checkout's records SHALL NOT stop a server that still hosts any session. A
failed listing SHALL count as not empty.

The pre-existing session test suite SHALL pass unchanged, except for
expectations that asserted a server stop while sessions remained.

#### Scenario: Existing tests stay green

- **WHEN** the seam has been introduced and no herdr session exists
- **THEN** every pre-existing session, orchestrator and nudge test passes with unchanged expectations, apart from the corrected server-stop rule

#### Scenario: Cleanup keeps a shared server that hosts other sessions

- **WHEN** every record of the current checkout is retired by `session cleanup`
- **AND** the dedicated tmux server still hosts the Orchestration Agent or another checkout's session
- **THEN** the tmux server keeps running and no `kill-server` is issued

#### Scenario: A failed listing never stops the server

- **WHEN** cleanup runs and the dedicated tmux server's session listing fails
- **THEN** cleanup does not stop the server

#### Scenario: An unsandboxed caller's tmux commands are unchanged

- **WHEN** a caller outside the OpenSpec execution sandbox runs any tmux backend operation
- **THEN** the tmux argv is byte-identical to the argv before this change

## ADDED Requirements

### Requirement: The shared tmux server is started only outside the OpenSpec sandbox

A caller inside the OpenSpec execution sandbox (`NOGG_OPENSPEC_FENCED=1`)
SHALL never start the dedicated tmux server. Every tmux command that the
tmux backend runs for such a caller SHALL carry tmux's global `-N` flag, so
a command that would normally start a server fails instead.

When such a caller runs `session launch` on the tmux backend and the
dedicated server is not running, the launch SHALL be refused before any
session record, effective-settings file or log is written. The refusal SHALL
say that a sandboxed session cannot start the shared server and SHALL point
to a launch from an unsandboxed shell (the operator or the Orchestration
Agent). A server listing that fails for another reason SHALL also refuse the
launch.

#### Scenario: A sandboxed first tmux launch is refused

- **WHEN** a Lead inside the OpenSpec execution sandbox runs `session launch` on the tmux backend
- **AND** the dedicated tmux server is not running
- **THEN** the launch is refused with a pointer to an unsandboxed launch
- **AND** no session record, effective-settings file, log or tmux server is created

#### Scenario: A sandboxed launch on a running server proceeds

- **WHEN** a Lead inside the OpenSpec execution sandbox runs `session launch` on the tmux backend
- **AND** the dedicated tmux server is running
- **THEN** the session starts on that server

#### Scenario: A server that exits during launch is not restarted from the sandbox

- **WHEN** the dedicated tmux server exits after a sandboxed launch's preflight and before its session is created
- **THEN** session creation fails, the record ends `failed`, and no tmux server is started inside the sandbox

### Requirement: A tmux server living in another namespace is reported

Nogging SHALL identify the process behind the dedicated tmux socket from the
socket's peer credentials, not from tmux's own PID report. It SHALL compare
that process's PID and mount namespaces with the caller's, and classify the
server as `host`, `sandboxed`, `outside`, `down` or `unknown`. An unfenced
caller whose server runs in another PID or mount namespace, and a fenced
caller whose server runs inside its own sandbox, SHALL classify the server
as `sandboxed`.

For a `sandboxed` server, `doctor` SHALL print a WARN that names the server
process and says that every session on it ends with that namespace, without
changing its exit status. `session list` SHALL print one NOTE. `orchestrator
status` SHALL show the classification. `orchestrator run` and an unsandboxed
`session launch` SHALL print a warning when they start or adopt a session on
such a server, and then continue. Nogging SHALL NOT kill, restart or signal
the tmux server because of this classification.

#### Scenario: A server born in a sandbox is visible from the host

- **WHEN** the dedicated tmux server runs in a PID or mount namespace other than the host caller's
- **THEN** `doctor` prints a WARN naming the server process, and its exit status is unchanged
- **AND** `orchestrator status` reports the server as `sandboxed`

#### Scenario: A host server is not reported

- **WHEN** the dedicated tmux server runs in the host caller's PID and mount namespace
- **THEN** `doctor` prints no tmux server WARN and `orchestrator status` reports it as `host`

#### Scenario: Reporting never stops the server

- **WHEN** the dedicated tmux server is classified as `sandboxed`
- **THEN** no `kill-server`, signal or restart is issued for it
