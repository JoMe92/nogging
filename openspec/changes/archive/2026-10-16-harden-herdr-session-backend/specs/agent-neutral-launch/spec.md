## ADDED Requirements

### Requirement: Exact conversation resume covers Codex

`scripts/nogg session launch --resume <id>` SHALL support Claude, Codex and
Antigravity.

For Codex:

- `<id>` SHALL be a Codex thread ID in UUID form. An invalid ID SHALL be
  refused before any worktree, trust, usage reservation, session record or
  backend side effect.
- The session SHALL run `codex resume <id>` inside the unchanged Nogging
  launch wrapper, with exactly the authority flags a cold launch at the same
  authority level uses.
- The launch prompt SHALL NOT be re-sent as a new first message.
- The record SHALL store the resumed thread ID as its Codex thread, so that
  `send`, `nudge` and kickoff reach that thread.
- When the installed Codex does not accept a required authority flag on
  `codex resume`, the resume SHALL be refused before any side effect. No flag
  SHALL ever be dropped silently.

#### Scenario: A Codex conversation resumes exactly

- **WHEN** `session launch --agent codex --resume <thread-id> …` runs with a valid thread ID
- **THEN** the session runs `codex resume <thread-id>` under the Nogging launch wrapper with the same authority flags as a cold launch
- **AND** the record's Codex thread is `<thread-id>`

#### Scenario: An invalid Codex resume ID is refused early

- **WHEN** `session launch --agent codex --resume not-a-uuid …` runs
- **THEN** the launch is refused and no worktree, record or backend session is created
