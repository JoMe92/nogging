## ADDED Requirements

### Requirement: Codex's collapsed paste placeholder is this operation's own pending paste

When the composer was verified empty before this operation pasted, and the
message is long or multi-line, a Codex composer whose sole content is exactly one
`[Pasted Content N chars]` token (N a positive integer) SHALL count as this
operation's pending message for `session send`, `session nudge` and
`session kickoff`. A placeholder present before the paste, extra typed text, more
than one placeholder, an image token, or a short message SHALL NOT match and
SHALL be refused with nothing submitted. N SHALL NOT be compared with the message
length. A footer hint outside the composer rows SHALL NOT affect the result.
Submission SHALL be verified by the composer leaving the placeholder state or a
fresh receipt, with the existing bounded single-retry Enter policy.

#### Scenario: A ~1000-character kickoff is accepted and submitted

- **WHEN** a 1000-plus-character kickoff is pasted into a verified-empty Codex composer that collapses it to `[Pasted Content N chars]`
- **THEN** exactly one Enter submits it and no second paste is typed

#### Scenario: A planning kickoff of 866 characters is accepted

- **WHEN** the exact planning kickoff composed for a Codex planner is pasted into a verified-empty composer and collapses to the placeholder
- **THEN** it is submitted once and the kickoff is recorded as delivered

#### Scenario: A multi-line message is accepted

- **WHEN** a short multi-line message collapses to the placeholder on a verified-empty composer
- **THEN** it is submitted once

#### Scenario: A foreign placeholder is never claimed

- **WHEN** the placeholder was already in the composer before the send, carries extra typed text, or appears twice
- **THEN** nothing is typed or submitted and the refusal says the composer did not hold exactly the message

#### Scenario: A swallowed Enter is retried once

- **WHEN** the first Enter leaves the placeholder in place
- **THEN** one retry is sent and a second failure is reported as unsubmitted

### Requirement: Codex kickoff waits for the startup turn and Enter waits for an idle turn

A Codex session launched with a startup prompt SHALL NOT be ready for kickoff
until the exact thread's rollout shows a `task_started` from this launch followed
by a terminal event with no later start. A session with no startup prompt, such
as a resume, SHALL keep the existing readiness rule. A thread that cannot be
resolved, an unreadable rollout or no completed startup turn SHALL be reported as
missing evidence and SHALL fail at the startup timeout with nothing typed, keyed
or queued. Unknown rollout event names SHALL be ignored. Delivery to Codex SHALL
press Enter only while the pane is not classified `working` and, where the thread
resolves, the turn state is not `running`. If the owned text stays pending until
the delivery deadline the operation SHALL fail stating that the text remains in
the composer, that Codex was busy and that it was not submitted.

#### Scenario: Kickoff does not run before the startup turn starts

- **WHEN** the Codex composer is empty and steady but the rollout shows no completed startup turn
- **THEN** the kickoff waits and the timeout names the missing startup-turn evidence

#### Scenario: Kickoff proceeds after the acknowledgement finishes

- **WHEN** the rollout shows `task_started` then `task_complete` for this launch and the composer is empty
- **THEN** the kickoff is delivered and submitted once

#### Scenario: Enter is held while the first turn is still finishing

- **WHEN** the kickoff text is pending and the turn is still running
- **THEN** no Enter is sent until the turn ends, then one Enter submits it

#### Scenario: A busy turn at the deadline is reported honestly

- **WHEN** the turn is still running at the delivery deadline
- **THEN** the error says the text is still in the composer and was not submitted, and success is never printed

#### Scenario: A resumed Codex session needs no startup turn

- **WHEN** a Codex session was started with `resume`
- **THEN** readiness uses the existing composer rule only

### Requirement: Codex queue is used only for an idle session

Before invoking `codex queue`, delivery SHALL establish that Codex is not busy
from three signals: the pane is not classified `working`, the backend agent
status is not `working` or `blocked`, and the exact thread's turn state is not
`running` where the thread resolves. A busy session SHALL be polled at the verify
interval until idle or the delivery deadline, and at the deadline the operation
SHALL refuse with a message that nothing was queued, typed or keyed, without
invoking `codex queue`, and SHALL name the alternatives. On an idle session a
fresh receipt remains the only success evidence; an accepted call without a
receipt or pending composer text SHALL remain the unverified error, SHALL NOT be
requeued, retyped or sent to the pane, and SHALL name the thread (first 8
characters) and the receipt-scan outcome. `session nudge --message` SHALL follow
the same rule.

#### Scenario: A busy session is never sent a queued message

- **WHEN** Codex is working and does not become idle before the deadline
- **THEN** `codex queue` is not invoked, the refusal says it was not queued or typed, and no success is reported

#### Scenario: A session that becomes idle in time is delivered

- **WHEN** Codex finishes its turn within the delivery window
- **THEN** `codex queue` is invoked exactly once and a fresh receipt is reported as submitted

#### Scenario: An idle session with a receipt is submitted

- **WHEN** Codex is idle, the queue call exits 0 and the receipt appears in the exact thread's rollout
- **THEN** the send is reported as a codex queue delivery

#### Scenario: Acceptance without evidence is never repeated

- **WHEN** the queue call exits 0 on an idle session and neither a receipt nor pending text appears
- **THEN** the operation fails as unverified, names the thread prefix, and the queue call count stays one with nothing typed
