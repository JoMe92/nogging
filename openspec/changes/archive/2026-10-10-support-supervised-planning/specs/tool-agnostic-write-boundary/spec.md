## MODIFIED Requirements

### Requirement: An execution agent of any tool cannot persist an OpenSpec change

An execution agent — regardless of whether it runs
under Claude Code, Codex, or another tool — SHALL NOT be able to create, modify,
or delete a file under `openspec/changes/` or `openspec/specs/`. Another session holding a planning lock SHALL NOT grant an execution role write authority. The block SHALL
be anchored in the filesystem or the OS sandbox, not only in a Claude
Code-specific hook. The mechanical sync writer and ordinary git branch
operations SHALL be unaffected.

#### Scenario: A launched execution session cannot write openspec/

- **WHEN** a supervised session is launched for an execution role (not a planning role) including when a different planning session is active
- **THEN** an attempt by that session to write a file under `openspec/changes/` or `openspec/specs/` fails
- **AND** the failure does not depend on which agent tool the session runs

#### Scenario: The mechanical sync writer still mirrors closures

- **WHEN** the boundary is closed and a mapped Bead is closed and the sync pass runs
- **THEN** the sync writer updates the change's `execution-log.md` and task checkbox and commits as the `sync` writer

#### Scenario: Git branch operations are unaffected

- **WHEN** the boundary is closed and an operator runs `git switch`, `git merge`, or `git checkout` between branches that differ under `openspec/`
- **THEN** the operation succeeds and updates the `openspec/` files
