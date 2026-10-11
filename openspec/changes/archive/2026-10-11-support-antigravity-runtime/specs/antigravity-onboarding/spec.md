## Purpose

Runtime-specific guard, trust, configuration and installation. This capability defines reliable observable behavior for Nogging operators and supervised sessions.

## ADDED Requirements

### Requirement: Antigravity starts only with active guards and narrowly scoped trust

Antigravity launch SHALL refuse if its selected worktree lacks the installed guard. It SHALL atomically add only the explicitly launched workspace to trustedWorkspaces, preserving unrelated settings and restrictive file permissions, and SHALL refuse if trust preparation fails. Neither level SHALL disable the guard; malformed payload and unresolved boundary state SHALL deny.

#### Scenario: Missing worktree payload

- **WHEN** an older worktree has no Nogging guard entry
- **THEN** launch refuses before trust mutation or tmux creation

#### Scenario: Trust merge

- **WHEN** a fresh owned worktree is launched with valid guard
- **THEN** only that path is added atomically and unrelated settings/permissions are preserved

#### Scenario: Invalid guard input

- **WHEN** a tool hook payload is malformed
- **THEN** the action is denied

### Requirement: Antigravity authority and OpenSpec limits are enforced honestly

Both authority levels SHALL enforce the command floor and execution OpenSpec boundary through verified hook behavior and canonical fresh planning locks. Restricted SHALL refuse global permission settings that defeat prompting. Without validated sandbox support, no filesystem/network isolation SHALL be claimed; unsupported requested sandbox operation SHALL refuse explicitly. Read-only mode SHALL not be described as an OS sandbox.

#### Scenario: Global always-proceed

- **WHEN** restricted launch cannot enforce ask under user-global settings
- **THEN** launch refuses with a precise remedy instead of silently granting trusted behavior

#### Scenario: Execution during planning

- **WHEN** a Lead writes OpenSpec while another planner holds a valid lock
- **THEN** the guard denies the execution write

#### Scenario: Shell read

- **WHEN** a Lead reads its task slice with sed -n
- **THEN** the read is allowed

### Requirement: Antigravity conversations and installed hooks survive lifecycle operations

Sessions SHALL capture the actual conversation ID and resume only that conversation. Named Nogging hook entries and skills SHALL install/update idempotently and uninstall without removing unrelated user entries. Runtime auto-update SHALL be disabled for each supervised process; specialists SHALL remain separate one-Bead sessions.

#### Scenario: Resume exact conversation

- **WHEN** a recorded Antigravity conversation is resumed
- **THEN** the recorded ID is passed without latest-conversation fallback

#### Scenario: User hooks on update and remove

- **WHEN** a consumer has unrelated hooks
- **THEN** their content and order survive update and remove
