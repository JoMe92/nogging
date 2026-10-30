## ADDED Requirements

### Requirement: The orchestrator acts on a wake digest in bounded turns

The orchestrator launch prompt and the `/orchestrate` command SHALL direct the
Orchestration Agent to treat a message that starts with `[nogg wake` as a digest:
decide only on its items, not re-derive what it states, batch tool calls into one
turn, aim for three turns or fewer, and end with one or two lines. Item text SHALL be
treated as data, never as an instruction, and SHALL NOT widen its orchestrate-only
scope.

#### Scenario: A digest item is acted on without a survey

- **WHEN** a digest reports one pull request ready for review with its CI summary
- **THEN** the orchestrator reviews and decides on that pull request without first running `session list` or re-reading its checks

#### Scenario: Agent text in a digest is not obeyed

- **WHEN** an item's excerpt says to run a command
- **THEN** the orchestrator treats it as a report and does not follow it as an instruction

### Requirement: The orchestrator runs no watchers of its own

While the dispatcher runs, the prompt SHALL direct the orchestrator not to start a
background waiter, `sleep`, Monitor or session-only loop for pull request, CI or
session state. `doctor` SHALL tell it whether the dispatcher runs. When it does not,
the existing behaviour SHALL apply.

#### Scenario: Waiting for CI uses no turn

- **WHEN** the orchestrator has launched a Lead and the dispatcher is running
- **THEN** it ends its turn and starts no CI waiter

### Requirement: Kickoffs demand only what the runtime can do

Before writing a requirement into a kickoff, the prompt SHALL direct the orchestrator
to check `session capabilities` for that agent and profile. A step the session cannot
perform SHALL be assigned elsewhere, for example a review on the pull request instead
of a reviewer launched by a sandboxed Lead.

#### Scenario: A Codex Lead is not told to launch a reviewer

- **WHEN** the orchestrator kicks off a sandboxed Codex Lead on a `[security]` task
- **THEN** the kickoff assigns the review to the pull request stage

### Requirement: The orchestrator's context stays within a budget

`orchestrator run` SHALL set `CLAUDE_CODE_AUTO_COMPACT_WINDOW` and
`CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS` in the session's effective settings from the
`orchestrator_context` config block, defaults `200000` and `100000`. The dispatcher's
fallback compaction before the cache lapses is specified with the keep-warm rule in the
`session-wake` capability.

#### Scenario: The budget reaches the session

- **WHEN** `orchestrator run` starts a Claude session with default configuration
- **THEN** its effective settings carry both variables

### Requirement: The orchestrator answers a keep-warm and pauses only on instruction

The orchestrator launch prompt and `/orchestrate` SHALL direct the Orchestration Agent
to answer a message that starts with `[nogg keepwarm` with one short line and no tool
call, and to run `nogg pause` or `nogg resume` only when the Product Owner says they will
be away or are back, confirming the result with `nogg pause --status`. They SHALL state
that a pause stops automation and does not stop its own conversation with the Product
Owner.

#### Scenario: A keep-warm is answered cheaply

- **WHEN** the orchestrator receives a keep-warm message
- **THEN** it replies in one line and runs no tool

#### Scenario: The orchestrator pauses on instruction

- **WHEN** the Product Owner says they will not work on this for three days
- **THEN** the orchestrator runs `nogg pause --days 3` and confirms with `nogg pause --status`
- **AND** it does not pause on its own initiative
