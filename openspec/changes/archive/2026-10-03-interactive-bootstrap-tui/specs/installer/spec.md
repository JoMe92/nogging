## ADDED Requirements

### Requirement: Bootstrap offers a guided interactive mode without changing non-interactive behavior

`scripts/bootstrap` SHALL enter an interactive, dialog-driven mode when both
stdin and stdout are a terminal and `whiptail` is available or can be
installed, and SHALL otherwise run exactly as it did before this capability
existed. A `--non-interactive` flag SHALL force the non-interactive flow
regardless of terminal detection.

#### Scenario: A piped install stays non-interactive

- **WHEN** `scripts/bootstrap` runs via `curl -fsSL ... | bash`
- **THEN** it runs the existing non-interactive flow, unchanged
- **AND** no dialog is shown

#### Scenario: A downloaded, directly-run script offers the wizard

- **WHEN** `scripts/bootstrap` is downloaded and run directly in a real
  terminal, with `whiptail` available
- **THEN** it enters interactive mode

#### Scenario: --non-interactive overrides terminal detection

- **WHEN** `scripts/bootstrap --non-interactive` runs in a real terminal
- **THEN** it runs the non-interactive flow regardless

### Requirement: Interactive mode falls back cleanly when whiptail is unavailable

When interactive mode would otherwise apply but `whiptail` is missing and
cannot be installed, `scripts/bootstrap` SHALL print a NOTE naming the
reason and SHALL continue with the non-interactive flow rather than failing.

#### Scenario: A failed whiptail install does not block the run

- **WHEN** `scripts/bootstrap` cannot install `whiptail` (no `apt`, no
  network, or no permission)
- **THEN** it prints a NOTE and proceeds with the non-interactive flow
- **AND** the installation still completes

### Requirement: The wizard offers to authenticate each unauthenticated required tool

Interactive mode SHALL check GitHub, Claude Code, and Codex authentication
status and SHALL offer, for each one found unauthenticated, to hand the
terminal to that tool's own login command. An already-authenticated tool
SHALL show no dialog for that step. The wizard SHALL NOT read, store, or
echo any credential itself.

#### Scenario: An unauthenticated tool is offered a login

- **WHEN** the wizard finds Codex not authenticated
- **THEN** it offers a yes/no dialog to log in now
- **AND** answering yes hands the terminal to `codex login`

#### Scenario: An already-authenticated tool is skipped silently

- **WHEN** the wizard finds GitHub already authenticated
  (`gh auth status` succeeds)
- **THEN** it shows no dialog for GitHub authentication
