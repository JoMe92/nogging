## MODIFIED Requirements

### Requirement: Send verifies a message was actually submitted

`session send` SHALL verify submission by default for Claude, Codex and
Antigravity, including calls from kickoff and nudge. `--verify` SHALL remain
accepted and SHALL retain its explicit-verification meaning for other agents.
Success SHALL require evidence of this operation's message being submitted;
transport success alone and an already-working agent SHALL NOT suffice.

Pane delivery SHALL refuse existing actual input or an unidentifiable
composer before typing, directing the operator to explicit replacement with
`nudge --message`. It SHALL NOT silently merge or erase operator input.
Nudge SHALL retain its independently specified bounded replacement checks.
After typing, delivery SHALL allow processing time before one Enter. It
SHALL retry Enter at most once and only while the operation's message is
positively pending. It SHALL NOT retry by typing the message again.
Unknown evidence or exhausted waits SHALL fail non-zero without printing a
successful send, nudge or kickoff confirmation.

#### Scenario: An unsubmitted message is retried

- **WHEN** the operation's message remains positively pending after the initial Enter
- **THEN** submission is retried once after the configured processing interval
- **AND** a still-pending or unverified message fails non-zero

#### Scenario: Ordinary Claude send verifies without a flag

- **WHEN** plain `session send` targets Claude and the message remains in its composer
- **THEN** it performs bounded verification without requiring `--verify`
- **AND** it does not print success merely because text and keys were sent

#### Scenario: Existing operator input is preserved

- **WHEN** ordinary pane send finds unrelated actual input or an unknown composer
- **THEN** it refuses before typing or sending Enter and points to `nudge --message`

#### Scenario: A prior working state is not a receipt

- **WHEN** an agent was already working before the message was sent
- **THEN** that unchanged state alone cannot confirm the new message

### Requirement: `session launch` names the missing kickoff step, and `session kickoff` delivers it

Bare `session launch` SHALL name the missing first message and exact kickoff
command without sending anything. `session kickoff <name> [--message TEXT]`
SHALL wait for positively established startup readiness and deliver one
verified first instruction. With `--message` it SHALL use that exact text;
otherwise it SHALL compose from the recorded scope. Lead messages SHALL
name the authorized Bead and change; specialist messages SHALL name the
already-claimed Bead and forbid Main Worker mutations; planning messages
SHALL name the planning identifier and dedicated worktree and require that
session to acquire its own planning lock before spec writes.

Kickoff SHALL refuse non-running sessions and execution sessions without a
Bead when no explicit message is supplied. `launch --kickoff` SHALL chain
the same readiness and verification path and propagate its failure.
Waiting SHALL be bounded and configurable. A startup timeout, trust or
permission dialog, limit, failed session or unknown readiness SHALL never
cause speculative input or automatic dialogue acceptance. Diagnostics SHALL
name the session, missing evidence and the next operator action.
Concurrent or repeated attempts to deliver the same kickoff SHALL NOT
duplicate a confirmed or ambiguously accepted instruction.

#### Scenario: A bare launch names the missing step

- **WHEN** launch runs without `--kickoff`
- **THEN** it names the exact kickoff command and sends no first message

#### Scenario: Kickoff composes the expected message

- **WHEN** a running Lead is ready and kickoff has no explicit message
- **THEN** its authorized Bead and change instruction is sent and confirmed submitted

#### Scenario: Kickoff refuses on a non-running session

- **WHEN** kickoff targets a non-running session
- **THEN** it refuses with no keys or queue request

#### Scenario: Kickoff refuses with no message and no Bead

- **WHEN** an execution session has no Bead and no explicit message is supplied
- **THEN** kickoff refuses with no delivery attempt

#### Scenario: `--kickoff` chains automatically

- **WHEN** launch is given `--kickoff`
- **THEN** it returns success only after the readiness and verified kickoff path succeeds

#### Scenario: Planning kickoff needs no placeholder Bead

- **WHEN** a ready planning session has its recorded identifier and dedicated worktree
- **THEN** its instruction requires its own planning lock without claiming execution work

#### Scenario: Specialist kickoff respects delegation authority

- **WHEN** a ready specialist is assigned one already-claimed Bead
- **THEN** kickoff forbids claiming, re-statusing, closing, committing or selecting sibling work

#### Scenario: Claude starts slowly

- **WHEN** a live Claude session has not yet rendered a ready input box
- **THEN** kickoff waits within its deadline and types nothing before readiness

#### Scenario: Antigravity readiness arrives after thirty seconds

- **WHEN** the current startup turn finishes after thirty seconds but before the configured deadline
- **THEN** kickoff waits and sends the instruction once without requiring an operator retry

#### Scenario: Antigravity is idle without a Stop readiness event

- **WHEN** the exact live Antigravity process repeatedly reports idle or done with a positively empty composer
- **AND** no permission, trust, limit or working indication contradicts readiness
- **THEN** kickoff can establish readiness without inventing a conversation ID or bypassing hooks

#### Scenario: Readiness times out

- **WHEN** neither valid current hook evidence nor reliable live readiness appears before the deadline
- **THEN** kickoff fails with a readiness diagnostic and no input or queue request

#### Scenario: Repeated kickoff after ambiguous queue acceptance

- **WHEN** the same kickoff was accepted by the transport but its submission could not be confirmed
- **THEN** a repeated kickoff checks existing evidence and does not enqueue or type it again

### Requirement: Submit verification is agent-specific for Codex and Antigravity

Ordinary send, `send --verify`, `nudge --message` and kickoff SHALL use the
target agent's own evidence. They SHALL never infer pending input from the
last visible screen line or report success without established delivery.

For Codex:

- Queue delivery SHALL remain the primary route when the exact thread
  resolves. Queue acceptance SHALL NOT alone count as submission.
- Fresh submitted-user-message evidence for that thread and this operation
  SHALL confirm queue delivery even when the composer cannot be identified.
  Historical matching text or evidence from another thread SHALL NOT count.
- If the queue leaves this operation's exact text positively pending, a
  bounded Enter sequence SHALL recover it without typing the text again.
- No receipt with an empty or unknown composer SHALL fail as unverified;
  it SHALL NOT cause a second queue request or pane text fallback.
- Pane fallback SHALL be allowed only before queue acceptance, when the
  queue was not invoked or definitively refused without acceptance.
- A pending pane message after one retry SHALL fail as unsubmitted.

For Antigravity:

- The classifier SHALL read only the framed composer and ignore its
  permanent status bar and lines below the frame.
- After explicit pane delivery, an observed transition to backend working
  or done, or a known composer holding this message becoming empty or a
  placeholder, SHALL confirm submission. An already-working backend alone
  SHALL NOT confirm it.

Only positively identified pending input belonging to this operation SHALL
receive a retry Enter. Unknown or unrelated input SHALL receive none.

#### Scenario: A Codex message nudge does not report a false success

- **WHEN** Codex pane fallback leaves the message pending after one retry
- **THEN** nudge fails as unsubmitted and prints no success

#### Scenario: A Codex message nudge uses the queue

- **WHEN** the exact Codex thread resolves and fresh evidence confirms its queued message
- **THEN** nudge succeeds through the queue with no pane text injection

#### Scenario: Queue acceptance leaves the text in the composer

- **WHEN** queue exits zero but its exact message remains pending
- **THEN** Nogging submits that buffer with at most one retry and does not retype or requeue it

#### Scenario: Queue accepts but delivery remains unproven

- **WHEN** queue exits zero and no matching fresh receipt or identifiable pending message appears
- **THEN** the operation fails as unverified without falling back to typing or sending another Enter

#### Scenario: Old or foreign text is not delivery evidence

- **WHEN** a transcript contains the same text before this operation or in a different thread
- **THEN** that text does not confirm the operation

#### Scenario: Antigravity's status bar is not pending input

- **WHEN** a delivered message leaves an empty framed composer above a permanent status bar
- **THEN** verification succeeds without another Enter

## ADDED Requirements

### Requirement: Delivery waits and evidence collection are bounded and private

Delivery SHALL use finite validated processing, startup and verification
timeouts. Invalid values SHALL refuse before message injection. Evidence
collection SHALL read only the exact target's local session evidence within
bounded work and SHALL persist no transcript content or credentials.
Unknown runtime evidence SHALL remain unknown. The operator SHALL be told
when a transport accepted a message whose submission remains unproven, so
that it is not blindly resent.

#### Scenario: Invalid timing configuration

- **WHEN** a delay is negative, non-finite, boolean or not numeric
- **THEN** the operation refuses before queueing, typing or sending keys

#### Scenario: Unavailable transcript

- **WHEN** the target's transcript is missing, unreadable, replaced or unsupported
- **THEN** Nogging uses only other positively established evidence or fails as unverified
- **AND** it does not scan unrelated conversations or store their contents
