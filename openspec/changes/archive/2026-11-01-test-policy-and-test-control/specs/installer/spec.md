## ADDED Requirements

### Requirement: The installer renders a per-repository nightly test timer

`init` and `update` SHALL render `systemd/nogg-nightly-<slug>.service` and
`systemd/nogg-nightly-<slug>.timer` with the target's absolute path, unless `--no-systemd`
is given, and SHALL NOT enable them. The service SHALL run `scripts/nogg test nightly` at low
CPU and I/O priority, and the timer SHALL fire hourly between 01:17 and 05:17 local time. The
next steps SHALL name how to enable the timer, `remove` SHALL name it among the units to
disable, and `remove` SHALL name the nightly worktree when it exists.

#### Scenario: A consumer gains the units on update

- **WHEN** `update` runs in a repository installed before this change
- **THEN** both units are rendered for its slug and neither is enabled

#### Scenario: No systemd

- **WHEN** `init --no-systemd` runs
- **THEN** no nightly unit is written

### Requirement: Update announces the testing defaults once

When a target's `.nogging/config.json` has no `testing` block, `update` SHALL print one line
saying the testing defaults apply and where to set stages, and SHALL leave the file unchanged.
New installs SHALL scaffold a `testing` block with empty `stages`. Every new runtime module
SHALL be listed in the manifest and the package files, and new test files SHALL NOT be shipped.

#### Scenario: An upgrade with no block

- **WHEN** `update` runs and the config has no `testing` block
- **THEN** one notice names `docs/nogging/test-control.md` and the config is byte-identical

#### Scenario: A configured repository

- **WHEN** `update` runs and a `testing` block exists
- **THEN** no notice prints and the block is unchanged
