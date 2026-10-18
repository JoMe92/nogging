## ADDED Requirements

### Requirement: A fenced Lead integrates upstream through the host-side broker

When `NOGG_OPENSPEC_FENCED=1`, `nogg worktree rebase` SHALL NOT run git against
the worktree itself. It SHALL send one request to the sandbox broker named by
`NOGG_TASK_DONE_SOCKET` with exactly the keys `action` (`rebase`), `checkout`
(an absolute path), `mode` (`start`, `continue` or `abort`) and `session`. The
broker SHALL validate `checkout` with the same registered-worktree-root check as
the task tick, run the same refusing engine as a direct call on the host side,
and return `ok`, a `status` of `done`, `up-to-date`, `paused` or `refused`, and
the output. The broker SHALL accept no path other than `checkout`, no command and
no replacement text, and the existing `{bead_id, checkout}` task-done request
SHALL be unchanged. `scripts/openspec-sandbox --contract` SHALL advertise a
`rebase-broker` feature. A broker that predates the action, or a fenced caller
with no broker, SHALL produce a message that names the unfenced hand-off command
and changes nothing.

#### Scenario: A fenced Lead rebases without writing openspec itself

- **WHEN** a fenced Lead runs `worktree rebase` and upstream touched `openspec/`
- **THEN** the host-side broker performs the rebase, the client ran no git
  mutation, and the Lead's tree is up to date and clean

#### Scenario: The broker rejects an open-ended request

- **WHEN** a request carries an extra key, a relative path, an unregistered
  checkout or a mode other than the three allowed
- **THEN** the broker returns an error and runs nothing

#### Scenario: An older broker is handled honestly

- **WHEN** the session's broker does not know the rebase action
- **THEN** the client exits 1 with the hand-off command and no file, ref or journal
  was written

### Requirement: A fenced session is stopped before a raw rebase damages the tree

`scripts/hooks/pre-rebase` SHALL exit non-zero before git touches the working tree
when `NOGG_OPENSPEC_FENCED=1` or `openspec/` is not writable and the diff between
`HEAD` and the rebase upstream touches `openspec/`, naming `nogg worktree rebase`
as the supported command. It SHALL allow every other rebase, including any rebase
by a caller that can write `openspec/`. `scripts/install-hooks` SHALL install it
and the payload manifest SHALL ship it. The `no-autonomous-claim` and
`autonomous` launch prompts SHALL tell a session not to integrate upstream with
`git rebase`, `git merge` or `git pull` while `openspec/` is read-only, to use
`./scripts/nogg worktree rebase`, and never to reset a dirty tree it did not make.

#### Scenario: A raw rebase is refused before any write

- **WHEN** a fenced session runs `git rebase origin/develop` and upstream changed
  `openspec/`
- **THEN** the hook exits 1, no file in the worktree changed and the message names
  the supported command

#### Scenario: A rebase that cannot hurt is allowed

- **WHEN** upstream did not change `openspec/`, or the caller can write it
- **THEN** the hook allows the rebase

#### Scenario: The prompts carry the rule

- **WHEN** a Lead is launched with either prompt
- **THEN** the prompt text names `worktree rebase` and forbids the raw commands
