## ADDED Requirements

### Requirement: Watch classifies an idle Claude session stuck in manual mode distinctly

For a Claude session, `classify()` SHALL report `awaiting_manual_approval`
instead of `idle` when the pane is otherwise idle and its permission-mode
status line reads `⏸ manual mode on`. This state SHALL NOT apply to Codex
sessions, which have no equivalent status line.

#### Scenario: An idle manual-mode session is distinguished from plain idle

- **WHEN** a Claude session's pane shows an empty prompt and `⏸ manual mode
  on` in its status line
- **THEN** `classify()` reports `awaiting_manual_approval`, not `idle`

#### Scenario: A working or auto-mode session is unaffected

- **WHEN** a Claude session's pane shows `⏵⏵ auto mode on` or is otherwise
  classified `working`
- **THEN** `classify()` reports that state as before; `awaiting_manual_approval`
  never overrides a non-idle classification

### Requirement: `session launch` warns when a lead or specialist session will not act unattended

`scripts/nogg session launch` SHALL print a one-line warning to the
launching terminal when `--role lead` or `--role specialist:*` is launched
with none of `--profile`, `--prompt`, or `--full-access` given. The warning
SHALL name the session and state that it will not act without a human
attached. `--role orchestrator` SHALL never trigger this warning.

#### Scenario: A bare lead launch warns

- **WHEN** `session launch --role lead --bead <id>` runs with no `--profile`,
  `--prompt`, or `--full-access`
- **THEN** the launch output includes a warning naming the session and the
  restricted/manual-mode consequence

#### Scenario: An explicit profile suppresses the warning

- **WHEN** `session launch --role lead --bead <id> --full-access` runs
- **THEN** no such warning is printed

#### Scenario: Orchestrator launches are unaffected

- **WHEN** `session launch --role orchestrator` runs
- **THEN** no such warning is printed, regardless of profile arguments

### Requirement: `session launch` names the missing kickoff step, and `session kickoff` delivers it

`scripts/nogg session launch`'s success output SHALL name the fact that the
session will not act until it receives a first message, and the exact
follow-up command, whenever `--kickoff` was not passed. `scripts/nogg session
kickoff <name> [--message TEXT]` SHALL deliver that first message: with
`--message`, that exact text; without it, a message composed from the
session's own `bead_id` and the Bead's `openspec:change:` label, naming both
and directing the session to claim the Bead and proceed through that
change's `tasks.md` in order. `session kickoff` SHALL refuse, sending
nothing, when the named session is not `running`, or when no `--message` is
given and the session record carries no `bead_id`. `--kickoff` on `session
launch` SHALL chain a `session kickoff` call immediately after a successful
launch.

#### Scenario: A bare launch names the missing step

- **WHEN** `session launch --role lead --bead <id>` runs with no `--kickoff`
- **THEN** its output includes a line naming the missing kickoff step and
  the exact command to run

#### Scenario: Kickoff composes the expected message

- **WHEN** `session kickoff <name>` runs with no `--message` for a `running`
  session whose record carries a `bead_id`
- **THEN** a message naming that Bead ID and its change is sent to the
  session and is confirmed submitted

#### Scenario: Kickoff refuses on a non-running session

- **WHEN** `session kickoff <name>` runs for a session that is not `running`
- **THEN** it refuses with a clear error and sends nothing

#### Scenario: Kickoff refuses with no message and no Bead

- **WHEN** `session kickoff <name>` runs with no `--message` for a `running`
  session whose record carries no `bead_id`
- **THEN** it refuses with a clear error and sends nothing

#### Scenario: `--kickoff` chains automatically

- **WHEN** `session launch --role lead --bead <id> --kickoff` runs
- **THEN** the resulting session has already received its first message by
  the time the command returns

### Requirement: `session nudge` reliably submits a pane regardless of prior input

`scripts/nogg session nudge <name> [--message TEXT]` SHALL clear the
session's pane input line before sending anything. With `--message`, it
SHALL send that text after clearing. With no `--message`, it SHALL read the
pane's pending input text before clearing and resend exactly that text; if
the pane had no pending text, it SHALL send nothing further and report that
there was nothing to nudge. `session nudge` SHALL refuse, sending nothing,
when the named session is not `running`.

#### Scenario: A stale pre-filled suggestion is resubmitted

- **WHEN** a session's pane has non-empty, unsent text at its prompt
- **AND** `session nudge <name>` runs with no `--message`
- **THEN** the pane is cleared and that same text is resent and confirmed
  submitted

#### Scenario: An explicit message overrides stale pane content

- **WHEN** a session's pane has unrelated unsent text at its prompt
- **AND** `session nudge <name> --message "..."` runs
- **THEN** the pane is cleared first, then the given message is sent and
  confirmed submitted

#### Scenario: Nudging an empty pane is a reported no-op

- **WHEN** a session's pane prompt is empty
- **AND** `session nudge <name>` runs with no `--message`
- **THEN** nothing is sent and the command reports there was nothing to
  nudge

#### Scenario: Nudging a non-running session is refused

- **WHEN** `session nudge <name>` runs for a session that is not `running`
- **THEN** it refuses with a clear error and sends nothing

### Requirement: `send --verify` detects an unsubmitted Claude message, not only Codex

`scripts/nogg session send <name> "<message>" --verify`'s retry-on-
unsubmitted check SHALL detect pending input for a Claude session using the
same pane-reading mechanism `session nudge` uses, not only for Codex
sessions.

#### Scenario: A Claude send retries when left unsubmitted

- **WHEN** `session send <name> "..." --verify` runs against a Claude
  session
- **AND** the pane afterward shows that message still sitting unsubmitted
- **THEN** `send` retries the submit step once, exactly as it already does
  for Codex

### Requirement: `session sweep` reports whether a running session's own work still needs it

`scripts/nogg session sweep` SHALL report, for every `running` session with
a `bead_id`, one of `change-complete` (every Bead materialized under the
Bead's `openspec:change:` label is `closed`, and any pull request for the
session's worktree branch is `MERGED`), `bead-blocked` (the session's own
Bead or another Bead under the same label is `blocked`, naming the blocking
Bead), or `active` (neither). Each reported line SHALL also show whether the
pane currently has unsubmitted pending input and an idle-duration figure
derived from the session's worktree and log activity. `session sweep` SHALL
NOT stop, nudge, or otherwise change any session or Bead.

#### Scenario: A session whose change is fully merged is flagged complete

- **WHEN** every Bead under a running session's `openspec:change:` label is
  `closed` and that session's worktree branch has a `MERGED` pull request
- **THEN** `session sweep` reports that session as `change-complete`

#### Scenario: A session correctly self-blocked is flagged, not hidden

- **WHEN** a running session's own Bead, or a sibling Bead under the same
  change, is `status: blocked`
- **THEN** `session sweep` reports that session as `bead-blocked`, naming
  the blocking Bead

#### Scenario: A genuinely active session is reported as active

- **WHEN** a running session's assigned change has open, unblocked Beads and
  none of the above conditions hold
- **THEN** `session sweep` reports that session as `active`

### Requirement: `doctor` surfaces flagged sessions without a per-session manual audit

`scripts/nogg doctor` SHALL report one `NOTE` per currently running session
classified `awaiting_manual_approval`, `change-complete`, or `bead-blocked`,
naming the session and the reason, using the same detection `session sweep`
performs.

#### Scenario: A flagged session appears in one doctor pass

- **WHEN** one or more running sessions are `change-complete`,
  `bead-blocked`, or `awaiting_manual_approval`
- **AND** an operator runs `scripts/nogg doctor`
- **THEN** its output includes one `NOTE` per such session, naming it and
  the reason, without a separate `tmux capture-pane` per session
