## ADDED Requirements

### Requirement: doctor diagnoses Codex sandbox capability as notes

When `codex` is installed and supports `codex sandbox`, `scripts/nogg doctor` SHALL probe, under the same writable roots, network setting and Git SSH command a trusted Codex session would receive, whether the sandbox can create and remove a file in the shared Git directory and in the current worktree's Git directory. `doctor --sandbox` SHALL additionally probe an SSH fetch from `origin` (only when `origin` uses SSH, with a bounded timeout) and run `scripts/test` inside the sandbox with a configurable bounded timeout, naming failing suites. Plain `doctor` SHALL print a note that the network and test probes require `--sandbox`. Every probe outcome, including skipped with a reason, SHALL be printed as a `NOTE` line and SHALL NOT change doctor's exit status. Probes SHALL leave no file, ref or configuration change behind.

#### Scenario: Read-only Git metadata is reported, not failed

- **WHEN** the resolved Codex sandbox cannot write the worktree's Git directory
- **THEN** doctor prints a `NOTE` naming that directory as not writable in the Codex sandbox
- **AND** doctor's exit status is unchanged by it

#### Scenario: Opt-in network and test probes

- **WHEN** `doctor --sandbox` runs on a host where `origin` is an SSH remote
- **THEN** it prints `NOTE` lines for the SSH fetch result and the sandboxed `scripts/test` result

#### Scenario: Unsupported Codex build

- **WHEN** `codex` is absent or has no `codex sandbox` subcommand
- **THEN** doctor prints a `NOTE` that the sandbox diagnosis was skipped and why
