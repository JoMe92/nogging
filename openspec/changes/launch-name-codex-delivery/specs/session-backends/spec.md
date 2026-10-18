## ADDED Requirements

### Requirement: Session names are backend-safe and identical everywhere

Nogging SHALL derive every supervised session name through one shared pure
helper that lowercases, rewrites `.` and `:` to `_`, and rewrites any other
character outside `[a-z0-9_-]` to `-`. The generated name SHALL be the session
record's `name`, the log and settings file stem, `NOGG_SESSION_NAME`, the tmux
session name used by `new-session` and by every later `-t` target, and the herdr
pane and tab label. The Orchestration Agent's name SHALL use the same helper.
Each backend's `prepare` and `start` SHALL refuse, before any side effect, a name
the helper would change. Uniqueness SHALL still come from the nonce and the
existing collision check. Existing records and live sessions SHALL be unchanged.

#### Scenario: A hierarchical Bead ID launches on tmux

- **WHEN** a lead session is launched for a Bead ID containing `.` (for example `supply-doc-v0zu.1`)
- **THEN** the tmux session, every `-t` target, the record `name` and the log file all carry the identical `_`-rewritten name and the launch succeeds

#### Scenario: A colon in a role or Bead ID is rewritten

- **WHEN** a name input contains `:`
- **THEN** the generated name contains `_` in its place and no `:` or `.` reaches any backend argument

#### Scenario: herdr labels follow the record

- **WHEN** a session is launched on herdr for a Bead ID containing `.`
- **THEN** the pane label and tab label equal the record name

#### Scenario: A caller cannot bypass the helper

- **WHEN** a backend is asked to prepare or start a name containing `.` or `:`
- **THEN** it raises before creating anything and names the offending character

### Requirement: A failed launch leaves no backend session behind

If any step fails after the backend session or pane was created and before the
session is `running` and has survived the launch settle window, Nogging SHALL
remove what it created: the tmux backend SHALL `kill-session` that exact name and
the herdr backend SHALL close the pane or tab it created. The backend `start`
SHALL clean up its own half-completed start, and `_session_launch` SHALL clean up
every later failure, including a settle failure and any exception before the
`running` transition. The record SHALL be marked `failed` with an `exit_reason`
stating the original error and whether cleanup succeeded. A cleanup error SHALL
NOT replace the original error. Cleanup SHALL NOT use `kill-server` or touch a
session Nogging did not create. A kickoff refusal after the session is `running`
SHALL NOT be treated as a launch failure and SHALL NOT kill the session.

#### Scenario: A pipe-pane failure leaves no tmux session

- **WHEN** `new-session` succeeds and `pipe-pane` then fails
- **THEN** the tmux server holds no session by that name, the record is `failed`, and its exit reason names the pipe-pane error and the cleanup

#### Scenario: A settle failure is cleaned up

- **WHEN** the launcher raises between `start` and the `running` transition or in the settle window while the backend session still exists
- **THEN** the backend session is removed and the record is `failed`

#### Scenario: herdr removes its half-created pane

- **WHEN** a herdr start fails after the pane exists
- **THEN** that pane is closed and no labelled pane for the name remains

#### Scenario: Cleanup never harms neighbours

- **WHEN** cleanup runs while other sessions live on the same tmux server
- **THEN** only the failed launch's session is removed and no `kill-server` is issued

#### Scenario: A refused kickoff keeps a healthy session

- **WHEN** a launched session is `running` and its kickoff is later refused
- **THEN** the session is not killed and its record stays `running`

#### Scenario: Stop has nothing to clean up afterwards

- **WHEN** `session stop` runs on the failed record after a cleaned-up launch
- **THEN** it reports nothing to do, and no orphan session exists

### Requirement: A planning session's process identity is provable or the launch is refused

When a tmux session is started by a caller whose `/proc` cannot read the
backend-reported pane PID, Nogging SHALL obtain the process start token and PID
namespace from the launch wrapper, which runs as that PID inside the server's
namespace, through a private receipt written beside the session record. The
receipt SHALL be accepted only when its PID equals the backend-reported pane PID,
and the record SHALL then store `session_pid`, `session_pid_start`,
`session_pid_ns` and `session_pid_identity_source: wrapper`. For the `planning`
role, a launch for which no identity can be proven within the settle window SHALL
fail before kickoff, SHALL be cleaned up as a failed launch, and SHALL name the
remedy of launching from an unsandboxed shell. Other roles MAY run with null
identity fields and SHALL print a NOTE. Identity read by a launcher that can see
the PID SHALL be unchanged.

#### Scenario: A launcher that sees the PID is unchanged

- **WHEN** the launcher can read the pane PID's start token and namespace
- **THEN** the record carries them with no receipt required

#### Scenario: A foreign namespace yields identity from the wrapper

- **WHEN** the launcher cannot read the pane PID and the wrapper receipt matches the backend PID
- **THEN** the record carries the receipt's start token and namespace, and a planner in that session can take the planning lock

#### Scenario: A mismatching receipt is rejected

- **WHEN** the receipt's PID differs from the backend-reported pane PID
- **THEN** it is ignored and the identity is treated as unprovable

#### Scenario: A planner with no provable identity is refused and cleaned up

- **WHEN** a planning launch ends with no provable identity
- **THEN** the launch fails before kickoff, no backend session remains, and the error names launching from an unsandboxed shell

#### Scenario: A non-planning role launches with a NOTE

- **WHEN** a lead session has no provable identity
- **THEN** it keeps running with null identity fields and the launch prints a NOTE
