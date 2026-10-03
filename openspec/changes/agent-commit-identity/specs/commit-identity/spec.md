## ADDED Requirements

### Requirement: Each Nogging persona has a defined commit identity

Nogging SHALL maintain a roster mapping each persona (Planner, Lead,
Orchestrator, Sync, and each specialist) to a stable `user.name` and a
Tier-1 `user.email`. A persona entry MAY additionally carry a `github_app`
block naming a registered GitHub App for that persona, absent by default.

#### Scenario: Every persona has a Tier-1 identity

- **WHEN** the persona roster is read
- **THEN** every persona that can author a commit (Planner, Lead,
  Orchestrator, Sync) has a `user.name` and `user.email`
- **AND** every specialist persona has a `user.name` and `user.email` usable
  in a `Co-authored-by:` trailer

### Requirement: A session's worktree carries its persona's identity, isolated per worktree

`worktree plan` and `worktree implement` SHALL set
`extensions.worktreeConfig` on the shared repository (idempotently) and
SHALL set the allocated worktree's `user.name`/`user.email`, via
`git config --worktree`, to the identity of the persona that worktree is
for. This identity SHALL NOT be visible from, or affect, any other worktree
or the shared checkout's own configuration.

#### Scenario: A planning worktree carries the Planner identity

- **WHEN** `worktree plan` allocates a new planning worktree
- **THEN** that worktree's `user.name`/`user.email` are the `planner`
  persona's
- **AND** a commit made there carries that identity as its author

#### Scenario: An implementation worktree carries the Lead identity

- **WHEN** `worktree implement` allocates a new implementation worktree
- **THEN** that worktree's `user.name`/`user.email` are the `lead`
  persona's

#### Scenario: Identity does not leak between worktrees

- **WHEN** two worktrees for different personas exist simultaneously
- **THEN** each worktree's `git config --worktree --get user.name` returns
  only its own persona's identity
- **AND** the shared checkout's own `user.name` is unaffected by either

### Requirement: A specialist's contribution is credited via Co-authored-by

When a specialist's delegated, incorporated work is part of a commit, that
commit SHALL carry a `Co-authored-by:` trailer naming the specialist
persona's identity from the roster, in addition to the committing session's
own author identity.

#### Scenario: A specialist's work is credited on the Lead's commit

- **WHEN** a Lead session incorporates a specialist's delegated work into a
  commit
- **THEN** the commit message includes a `Co-authored-by:` trailer naming
  that specialist's persona identity

### Requirement: Tier-2 credential minting never persists a long-lived token

`scripts/nogg credential-helper <slug>` SHALL implement git's
credential-helper protocol, mint a short-lived GitHub App installation
access token on each invocation, and SHALL NOT write that token to disk.
When the named persona's App credentials are missing or the token exchange
fails, it SHALL fail closed — printing no credential and returning
non-zero — and SHALL NOT fall back to an ambient personal credential.

#### Scenario: A token is minted fresh on each push

- **WHEN** a push from a Tier-2-configured worktree needs a credential
- **THEN** `credential-helper` mints a new installation token for that
  request
- **AND** no token is written to disk afterward

#### Scenario: A missing key fails closed

- **WHEN** `credential-helper <slug>` runs and that persona's private key
  is not present at its configured path
- **THEN** it prints no credential and exits non-zero
- **AND** it does not fall back to any other credential source

### Requirement: A persona without a registered GitHub App stays on Tier 1

A persona's roster entry with no `github_app` block SHALL cause its
worktrees to use the Tier-1 `user.email` and the session's existing default
credential path, unaffected by Tier 2 being configured for any other
persona.

#### Scenario: Partial Tier-2 adoption is supported

- **WHEN** only some personas in the roster have a `github_app` block
  configured
- **THEN** worktrees for those personas use Tier-2 identity and credentials
- **AND** worktrees for every other persona use Tier-1 identity, unaffected
