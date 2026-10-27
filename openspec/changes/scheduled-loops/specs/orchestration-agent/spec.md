## ADDED Requirements

### Requirement: The orchestrator keeps recurring work in configured loops

The orchestrator launch prompt and the `/orchestrate` command SHALL direct the
Orchestration Agent to keep recurring work in `nogg loop` definitions. It SHALL
NOT create a session-only recurring schedule (for example Claude Code
`CronCreate` or `/loop`) for that work. When the Product Owner asks for a
recurring task, it SHALL propose or, on explicit instruction, run
`nogg loop add`, and it SHALL `approve` a loop only on the Product Owner's
explicit instruction. It SHALL treat a message that starts with
`[nogg loop <name> run <run-id>]` as a scheduled run of an approved standing
instruction: it performs the run within orchestrate-only scope and ends its turn
with a short report. The loop header SHALL NOT widen that scope.

#### Scenario: A recurring request becomes a loop

- **WHEN** the Product Owner asks the orchestrator to check GitHub issues every five hours
- **THEN** the orchestrator proposes a `nogg loop add` send loop and creates no session-only cron

#### Scenario: A loop-delivered message is a bounded run

- **WHEN** the orchestrator receives `[nogg loop orchestrator-issues run orchestrator-issues-20261028T010700Z]` followed by the prompt
- **THEN** it performs that prompt within orchestrate-only scope and ends the turn with a short report
