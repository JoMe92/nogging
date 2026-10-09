## MODIFIED Requirements

### Requirement: A project-local extension enforces the command floor and the write boundary

Because Pi ships no native sandbox or execution-policy mechanism, the
installer SHALL place `.pi/extensions/nogging-guard.ts`, a project-local
extension that intercepts the `tool_call` event to: deny a shell command
matching the Nogging command-floor patterns (`sudo`, `rm -rf`/`rm -fr`,
`dd`, `mkfs` and variants, `shutdown`, `reboot`, `systemctl`, `chown`,
`curl`, `wget`, `git push --force*`, `git reset --hard`, `git clean -fdx`,
`git filter-branch`); and deny a file write or edit under `openspec/` unless
a fresh planning lock and absent closed-boundary sentinel authorize a planning session. The guard SHALL resolve shared repository state from linked worktrees, use planning_lock_ttl_seconds (default 7200), and treat missing, stale, malformed or unreadable lock state and repository-resolution failures as closed. Execution roles SHALL remain unable to write OpenSpec even while another session is planning. Neither
`session launch --agent pi` at any authority level, nor any launch profile,
SHALL pass a flag or setting that prevents this extension from loading.

#### Scenario: A floor command is blocked

- **WHEN** a Pi session (trusted for this project) attempts a shell command matching a command-floor pattern
- **THEN** the guard extension blocks the call and reports why

#### Scenario: An openspec/ write is blocked outside a planning session

- **WHEN** a Pi session attempts to write or edit a file under `openspec/` while the write boundary is closed
- **THEN** the guard extension blocks the call

#### Scenario: An openspec/ write succeeds during planning

- **WHEN** the write boundary is open (a planning session is active)
- **AND** an authorized Pi planning session writes under `openspec/`
- **THEN** the guard extension allows the call
## ADDED Requirements

### Requirement: Pi worktree state lookup fails closed

A Pi guard in a linked worktree SHALL consult canonical repository locks; an absent worktree-local sentinel SHALL NOT imply authorization. Any closed sentinel found in authoritative state SHALL take precedence over a fresh lock.

#### Scenario: No local sentinel

- **WHEN** a linked worktree has no local locks directory and the canonical sentinel is closed
- **THEN** an OpenSpec write is denied

#### Scenario: Missing or stale lock

- **WHEN** no fresh valid planning lock can be established or git resolution fails
- **THEN** the boundary is closed
