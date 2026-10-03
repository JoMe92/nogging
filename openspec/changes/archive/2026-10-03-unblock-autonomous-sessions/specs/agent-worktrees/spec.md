## ADDED Requirements

### Requirement: A Claude Code session enters its allocated worktree without a blocking tool prompt

An autonomous Claude Code session that allocates an implementation or planning
worktree via `scripts/nogg worktree implement` / `worktree plan` SHALL be
instructed to switch into that worktree with a plain shell `cd`, not with the
`EnterWorktree` tool. Claude Code's own relocation-approval prompt for
`EnterWorktree` cannot be suppressed by any permission rule or "don't ask
again" selection — only `bypassPermissions` mode skips it — and Nogging's
`trusted` profile deliberately does not grant `bypassPermissions`, so an
unattended session that used `EnterWorktree` would block indefinitely on that
prompt with no operator present to answer it.

#### Scenario: An autonomous session is told to cd, not EnterWorktree

- **WHEN** the `autonomous` launch prompt instructs a session to allocate and
  enter an implementation or planning worktree
- **THEN** it instructs the session to `cd` into that worktree via Bash
- **AND** it instructs the session not to use the `EnterWorktree` tool for
  that worktree

#### Scenario: A full-access Lead session does not block entering its worktree

- **WHEN** a `--full-access` Lead session allocates its implementation
  worktree and switches into it per the `autonomous` prompt's instruction
- **THEN** no interactive relocation-approval prompt blocks the session
