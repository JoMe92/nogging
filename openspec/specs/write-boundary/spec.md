# write-boundary Specification

## Purpose
TBD - created by archiving change harden-openspec-write-boundary. Update Purpose after archive.

## Requirements

### Requirement: Discoveries use native Beads label and note

A material discovery raised by an execution agent SHALL be recorded on the
active Bead using the native Beads `discovery` label together with a
human-readable note. The system SHALL NOT require any serialized metadata block
(such as a fenced `specforge-discovery` JSON object) to record a discovery. The
mechanical sync SHALL identify pending discoveries by the `discovery` label
alone and surface them to the next planning session without interpreting them.

#### Scenario: Non-blocking discovery is recorded

- **WHEN** an execution agent records a non-blocking discovery on the active Bead
- **THEN** the Bead carries the `discovery` label
- **AND** the Bead has a human-readable note describing the discovery
- **AND** the Bead status is unchanged

#### Scenario: Blocking discovery is recorded

- **WHEN** an execution agent records a discovery that blocks the current task
- **THEN** the Bead carries the `discovery` label and a human-readable note
- **AND** the Bead status is set to `blocked`

#### Scenario: Planning session lists pending discoveries

- **WHEN** a planning session asks for pending discoveries
- **THEN** the system returns every open Bead carrying the `discovery` label
- **AND** it does not parse or transform the note contents

### Requirement: Execution commits carry a real Beads issue ID

A commit that is not marked as a planning or sync writer SHALL be rejected
unless its subject line contains a real Beads issue ID token of the form
`[<PREFIX>-<id>]` (for example `[SPEC-abc]`). A placeholder token that is not a
real issue ID SHALL NOT satisfy this requirement.

#### Scenario: Execution commit with a Beads ID is accepted

- **WHEN** a commit is made without the planning or sync writer marker
- **AND** the subject line contains a real Beads issue ID token such as `[SPEC-abc]`
- **THEN** the commit is accepted

#### Scenario: Execution commit without a Beads ID is rejected

- **WHEN** a commit is made without the planning or sync writer marker
- **AND** the subject line contains no real Beads issue ID token
- **THEN** the commit is rejected with a message that names the rule and the exemption mechanism

### Requirement: Planning and sync commits are exempt from the Beads ID rule

A commit whose `SPECFORGE_WRITER` environment value is `planning` or `sync`
SHALL be accepted without a Beads issue ID token, because those two writers are
the only writers permitted to modify `openspec/` and they commit deterministic
plan or mirror state rather than execution work.

#### Scenario: Planning commit without a Beads ID is accepted

- **WHEN** a commit is made with `SPECFORGE_WRITER` set to `planning`
- **AND** the subject line contains no Beads issue ID token
- **THEN** the commit is accepted

#### Scenario: Sync commit without a Beads ID is accepted

- **WHEN** a commit is made with `SPECFORGE_WRITER` set to `sync`
- **AND** the subject line contains no Beads issue ID token
- **THEN** the commit is accepted

### Requirement: Tool-level enforcement of the OpenSpec write boundary

The Claude Code configuration SHALL include a `PreToolUse` hook matching the
`Edit` and `Write` tools that blocks the tool call when the target path is
under `openspec/` and `.specforge/locks/planning.lock` does not exist. When the
planning lock exists, the hook SHALL allow the tool call. The hook SHALL NOT
interfere with edits to paths outside `openspec/`.

#### Scenario: Write into openspec without the planning lock is blocked

- **WHEN** an `Edit` or `Write` targets a path under `openspec/`
- **AND** `.specforge/locks/planning.lock` does not exist
- **THEN** the tool call is blocked before it runs
- **AND** the agent receives a message explaining that `openspec/` is writable only in a planning session

#### Scenario: Write into openspec with the planning lock is allowed

- **WHEN** an `Edit` or `Write` targets a path under `openspec/`
- **AND** `.specforge/locks/planning.lock` exists
- **THEN** the tool call proceeds

#### Scenario: Write outside openspec is unaffected

- **WHEN** an `Edit` or `Write` targets a path outside `openspec/`
- **THEN** the hook does not block the tool call regardless of the planning lock
