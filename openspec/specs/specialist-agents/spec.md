# specialist-agents Specification

## Purpose
TBD - created by archiving change specialist-agents-and-skills. Update Purpose after archive.

## Requirements

### Requirement: The six specialist subagents are defined as invocable agents

The repository SHALL define six specialist subagents as `.claude/agents/*.md`
files — `architect`, `ui-ux-designer`, `backend-engineer`, `frontend-engineer`,
`code-reviewer`, `test-runner` — each with exactly one stated responsibility and
a tool set scoped to that responsibility. `architect` and `code-reviewer` SHALL
NOT be granted the ability to modify source files. `architect` SHALL be usable
by both the Lead Agent and the Planning Agent; the other five SHALL be for Lead
Agent use.

#### Scenario: Each specialist has a definition file

- **WHEN** the repository is inspected
- **THEN** `.claude/agents/` contains a definition file for each of `architect`, `ui-ux-designer`, `backend-engineer`, `frontend-engineer`, `code-reviewer`, and `test-runner`
- **AND** each file states a single responsibility and the tools that role may use

#### Scenario: Advisory agents cannot modify source

- **WHEN** the `architect` or `code-reviewer` definition is inspected
- **THEN** it grants no source-editing capability and states that its output is analysis or findings returned to the caller

### Requirement: Specialists operate only within execution boundaries

A specialist subagent SHALL NOT create, edit, or delete any file under
`openspec/`. It SHALL act on exactly the one Bead the Lead Agent names when
delegating, and SHALL NOT enumerate ready work or act on other Beads. It SHALL
NOT claim a Bead, close a Bead, change a Bead's status, or create a git commit.
It SHALL return a structured result to the Lead Agent describing what was done,
which files changed, and how the work was validated.

#### Scenario: A specialist does not touch OpenSpec

- **WHEN** a delegated specialist would need to change agreed intent to finish the task
- **THEN** it does not edit `openspec/`
- **AND** it reports the blocker to the Lead Agent instead

#### Scenario: A specialist works only the delegated Bead

- **WHEN** the Lead Agent delegates a task naming one Bead ID
- **THEN** the specialist acts only on that Bead
- **AND** it does not run ready-work enumeration or claim, close, or re-status any Bead

#### Scenario: A specialist does not commit

- **WHEN** a specialist finishes its implementation work
- **THEN** it leaves the changes uncommitted and returns control to the Lead Agent
- **AND** the Lead Agent is responsible for validation, the evidence note, the commit, and closing the Bead

### Requirement: Specialists surface plan-relevant findings to the Lead Agent

When a specialist encounters a finding that would change agreed intent or needs
a decision the task does not contain, it SHALL stop and report the finding, with
its evidence, to the Lead Agent. It SHALL NOT add the `discovery` label to a
Bead, mark a Bead blocked, or deviate from the specified task on its own
initiative. Recording the discovery on the Bead remains a Lead Agent action.

#### Scenario: A specialist reports a discovery rather than acting on it

- **WHEN** a specialist determines the delegated task cannot be completed as specified
- **THEN** it returns a report to the Lead Agent naming the finding and the evidence
- **AND** it does not label or re-status the Bead itself

### Requirement: The Lead Agent delegates implementation and retains Bead ownership

`CLAUDE.md` SHALL define that the Lead Agent, after claiming a Bead and reading
its task slice, either implements the work directly or delegates it to one
specialist through the Task tool, passing the Bead ID and the relevant task and
spec excerpts. Claiming, closing, committing, writing the evidence note, and
reading OpenSpec SHALL remain Lead Agent actions. OpenSpec SHALL remain
read-only for the Lead Agent.

#### Scenario: Delegation is defined in CLAUDE.md

- **WHEN** `CLAUDE.md` is read at session start
- **THEN** it describes delegating isolated implementation to a specialist via the Task tool
- **AND** it states that claiming, closing, committing, and OpenSpec reads stay with the Lead Agent

#### Scenario: AGENTS.md points to the model without duplicating it

- **WHEN** `AGENTS.md` is read by a non-Claude tool
- **THEN** it references `.claude/agents/` and the `CLAUDE.md` delegation section
- **AND** it states that isolated implementation may be delegated while claiming, closing, and committing stay with the Main Worker

### Requirement: Materialized Beads carry a resolvable task reference

Every Bead created by `scripts/specforge materialize` SHALL carry an
`openspec:change:<name>` label and an `openspec:task:<TASK-ID>` label, and the
`openspec:task:<TASK-ID>` label SHALL resolve to exactly one task line in that
change's `tasks.md`. This lets the Lead Agent read only the referenced task
slice and spec excerpt when briefing a specialist.

#### Scenario: Materialize sets both labels

- **WHEN** `scripts/specforge materialize <change>` creates a Bead for a task
- **THEN** the Bead carries `openspec:change:<change>` and `openspec:task:<TASK-ID>`
- **AND** `openspec:task:<TASK-ID>` matches exactly one `- [ ]` or `- [x]` task line in `openspec/changes/<change>/tasks.md`

#### Scenario: A Bead with an unresolvable task reference is rejected by validation

- **WHEN** a Bead carries an `openspec:task:<TASK-ID>` label that matches no task line in its change
- **THEN** `scripts/specforge validate` reports it as a problem
