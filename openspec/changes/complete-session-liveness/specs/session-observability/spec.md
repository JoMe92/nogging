## MODIFIED Requirements

### Requirement: `session nudge` reliably submits a pane regardless of prior input

Session nudge SHALL refuse non-running sessions. With --message it SHALL deliberately replace actual pending input and submit the supplied text with bounded verification. Without --message it SHALL resend only positively identified actual input; placeholder suggestions and ambiguous pane text SHALL never be executed and SHALL produce a no-op or request for an explicit message.

#### Scenario: Placeholder-only prompt

- **WHEN** an idle pane displays only a suggested next instruction and nudge has no message
- **THEN** nothing is submitted and the operator is told to provide an explicit message

#### Scenario: Explicit replacement

- **WHEN** nudge receives --message for a running session
- **THEN** the supplied message replaces actual prior input and is verified submitted

#### Scenario: Non-running session

- **WHEN** nudge targets a stopped session
- **THEN** no keys or message are sent


#### Scenario: A stale pre-filled suggestion is resubmitted

- **WHEN** a pane shows a stale suggested placeholder and the operator supplies that instruction explicitly with --message
- **THEN** the supplied instruction is submitted; the suggestion alone is never automatically executed

#### Scenario: An explicit message overrides stale pane content

- **WHEN** nudge receives --message and the session has unrelated actual buffered input
- **THEN** the explicit message replaces the actual input and is verified submitted

#### Scenario: Nudging an empty pane is a reported no-op

- **WHEN** nudge has no message and no actual buffered input can be positively identified
- **THEN** no text is submitted and the command reports that an explicit message is needed

#### Scenario: Nudging a non-running session is refused

- **WHEN** nudge targets a non-running session
- **THEN** it refuses without sending input

### Requirement: `session sweep` reports whether a running session's own work still needs it

Session sweep SHALL distinguish change-complete, bead-blocked and active for the session authorized scope, and SHALL expose unknown evidence rather than inventing completion. A blocked unrelated sibling SHALL NOT block runnable assigned work. Completion SHALL require mapped work closed and merged PR or explicit integration evidence; open or unknown integration status SHALL prevent completion. Sweep SHALL show idle duration and input certainty separately and SHALL NOT stop, nudge or claim work.

#### Scenario: Unrelated blocked sibling

- **WHEN** the assigned task is runnable while a sibling outside its dependency cone is blocked
- **THEN** the session is not classified bead-blocked solely because of that sibling

#### Scenario: Integrated complete scope

- **WHEN** all authorized mapped work is closed and integration is evidenced
- **THEN** the session is classified change-complete

#### Scenario: Unknown PR

- **WHEN** PR lookup or cached integration evidence is unavailable
- **THEN** the session is not marked complete and unknown evidence is visible


#### Scenario: A session whose change is fully merged is flagged complete

- **WHEN** every mapped Bead in the authorized change is closed and its PR is verified merged
- **THEN** sweep reports change-complete

#### Scenario: A session correctly self-blocked is flagged, not hidden

- **WHEN** its own assigned Bead or an unmet dependency in its authorized scope is blocked
- **THEN** sweep reports bead-blocked with the blocking Bead ID; an unrelated sibling alone does not qualify

#### Scenario: A genuinely active session is reported as active

- **WHEN** assigned work is runnable and completion or blocking evidence does not apply
- **THEN** sweep reports active with separate idle/input evidence

## ADDED Requirements

### Requirement: CI observations are explicit and bounded

Session sweep --checks SHALL expose PR head/check fingerprints and whether they have been explicitly acknowledged. Doctor SHALL use cached evidence without mandatory remote calls. New or changed checks SHALL remain unchecked until an explicit checks-ack observation; missing/stale/network-failed evidence SHALL be visible as unknown.

#### Scenario: New failed checks

- **WHEN** a PR check fingerprint changes after its last acknowledgement
- **THEN** sweep --checks reports the failure as unchecked and doctor can show the cached result

#### Scenario: Read-only inspection

- **WHEN** sweep observes checks without checks-ack
- **THEN** the observation is not silently acknowledged

### Requirement: Stale hook state cannot pin a resolved permission prompt

Structured session events SHALL be reconciled with current live evidence when the last needs_input event is stale or contradicted by a resolved prompt. A missing Stop event SHALL NOT indefinitely override a reliable live idle/working classification; fresh active prompts SHALL remain needs_input.

#### Scenario: Denied tool without Stop

- **WHEN** a needs_input event remains but the live pane shows the prompt resolved
- **THEN** watch reports current live state rather than permanently needs_input
