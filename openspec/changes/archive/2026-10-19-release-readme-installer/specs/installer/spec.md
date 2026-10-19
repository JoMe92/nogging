## MODIFIED Requirements

### Requirement: init leaves the repository ready to start

`init` SHALL bring the target repository to a state where a planning session can
begin immediately. It SHALL initialize the Beads issue tracker in the repository
unless `--no-beads` is given, and this step SHALL be idempotent — an already
initialized tracker is left untouched. A failure to initialize Beads (for
example an unreachable storage backend) SHALL be reported as a warning and
SHALL NOT abort the install.

After writing every file, `init` and `update` SHALL run the readiness check and
end with an explicit verdict line. The line is either
`Nogging is ready — …` or `Nogging is installed but not ready: <gap>; <gap>`.
A ready verdict SHALL point to starting a plan through `/plan` or
`./scripts/nogg worktree plan`, never to `plan-begin` in the shared checkout.
Gaps SHALL be deduplicated. A missing Beads database SHALL be reported as the
uninitialized-tracker gap, and a gap SHALL NOT show a command line built from
internal arguments. Each gap SHALL be followed by a fix hint on its own line,
and no following line SHALL repeat the verdict prefix. The installer's
`doctor` command SHALL print the unchanged `doctor` report followed by the
same verdict, without running the checks twice, and SHALL exit with
`doctor`'s status.

#### Scenario: Fresh repository is initialized and reported ready

- **WHEN** `init` runs in a repository with no Beads tracker and all prerequisites present
- **THEN** a Beads tracker is initialized in the repository
- **AND** the final output states that Nogging is ready and names `/plan` or `./scripts/nogg worktree plan` as the way to start

#### Scenario: Existing tracker is preserved

- **WHEN** `init` runs in a repository that already has an initialized Beads tracker
- **THEN** the existing tracker is left unchanged
- **AND** the install still completes

#### Scenario: Beads opt-out

- **WHEN** `init` runs with `--no-beads`
- **THEN** no Beads tracker is initialized
- **AND** the readiness verdict lists the uninitialized tracker as outstanding

#### Scenario: Missing prerequisite is named

- **WHEN** `init` runs on a host where a required tool is not installed
- **THEN** the install completes
- **AND** the final verdict names the missing tool rather than claiming readiness
- **AND** a fix hint for that tool follows the verdict

#### Scenario: A missing tracker database is reported once

- **WHEN** `init --no-beads` runs on a host where `bd` is installed but the repository has no Beads database
- **THEN** the uninitialized tracker is the only gap in the verdict
- **AND** no `bd list` command text appears in the output

#### Scenario: The installer's doctor ends with the verdict

- **WHEN** the installer's `doctor` command runs
- **THEN** the full `scripts/nogg doctor` report is printed once, followed by the readiness verdict
- **AND** the exit status equals that of `scripts/nogg doctor`

### Requirement: Public installation guidance matches installer behavior

The CLI help, bootstrap usage, README, and installation reference SHALL agree
on prerequisites, supported platforms, files created or overwritten, default
Beads initialization, every option, version pinning, Git-hook interaction,
systemd and non-systemd operation, Claude/Codex/Pi payloads, preflight,
next steps, and readiness outcomes. The prerequisites the installation
reference lists SHALL match the installer's preflight table by tool name,
minimum version, and required or optional class. Examples SHALL use portable
paths and the current stable tag or a clearly defined version placeholder.
A test SHALL compare these surfaces.

#### Scenario: Documentation and CLI are compared

- **WHEN** the documented flags, payload table, prerequisites, and post-install steps are checked against a fresh install and CLI help
- **THEN** every supported option and written path is represented accurately
- **AND** no instruction assumes the maintainer's home directory, private-repository authentication, or obsolete release tag

#### Scenario: A flag drifts between surfaces

- **WHEN** an option is present in the CLI help or the bootstrap usage but missing from the installation reference, or the reverse
- **THEN** the install-surface consistency test fails and names the option and the surface

#### Scenario: A README install command drifts

- **WHEN** an install command in `README.md` does not appear verbatim in the installation reference
- **THEN** the install-surface consistency test fails and names the command

### Requirement: Bootstrap offers a guided interactive mode without changing non-interactive behavior

`scripts/bootstrap` SHALL enter an interactive, dialog-driven mode when both
stdin and stdout are a terminal and `whiptail` is available or can be
installed, and SHALL otherwise run the non-interactive flow. A
`--non-interactive` flag SHALL force the non-interactive flow regardless of
terminal detection. The wizard SHALL only change how the target and options
are chosen. Both flows SHALL run the same steps and print the same plan block
and closing summary, and the non-interactive flow SHALL never show a dialog
or wait for input.

#### Scenario: A piped install stays non-interactive

- **WHEN** `scripts/bootstrap` runs via `curl -fsSL ... | bash`
- **THEN** it runs the non-interactive flow
- **AND** no dialog is shown and no input is awaited

#### Scenario: A downloaded, directly-run script offers the wizard

- **WHEN** `scripts/bootstrap` is downloaded and run directly in a real
  terminal, with `whiptail` available
- **THEN** it enters interactive mode

#### Scenario: --non-interactive overrides terminal detection

- **WHEN** `scripts/bootstrap --non-interactive` runs in a real terminal
- **THEN** it runs the non-interactive flow regardless

#### Scenario: Both modes end with the same summary

- **WHEN** the same options are chosen once through the wizard and once through flags
- **THEN** both runs print the same plan block and the same closing summary text

## ADDED Requirements

### Requirement: The installer preflights required tools with fix hints

Before writing, and also under `--dry-run`, `init` and `update` SHALL check
the host against a single preflight table. The required tools are Node.js,
Git, Bash, Python 3, the OpenSpec CLI, `bd` and Dolt, each with its
supported minimum. The optional tools are tmux or herdr, systemd user
services unless `--no-systemd` is given, and at least one agent CLI. The
preflight SHALL report each missing, too old or unreadable tool on one line
with a concrete fix hint. When every required tool passes, it SHALL print a
single summary line. A bootstrap hint SHALL name the installing package's
own version. The preflight SHALL be advisory: it SHALL NOT change the exit
status, block or alter any write, install anything, or use the network. A
probe that does not answer within its timeout SHALL be reported as unknown.

#### Scenario: A required tool is missing

- **WHEN** `init` runs on a host without the OpenSpec CLI
- **THEN** the preflight names the OpenSpec CLI as missing with an install hint
- **AND** the install writes exactly the files it writes on a host with every tool present

#### Scenario: A tool is too old

- **WHEN** `init` runs with a Git older than the supported minimum
- **THEN** the preflight names Git, the found version, and the minimum

#### Scenario: A probe hangs

- **WHEN** a tool's version probe does not return within the timeout
- **THEN** the preflight reports that tool as unknown and the install continues

#### Scenario: Every required tool is present

- **WHEN** `init` runs on a host with every required tool at a supported version
- **THEN** the preflight prints one summary line

### Requirement: Installer output is grouped and reports each path once

`init`, `update` and `remove` SHALL begin with a header line naming the
Nogging version (for `update`, the previous and new version), the command,
the target repository, and whether it is a dry run. Changes SHALL be
summarized per file class with counts per action, and files that did not
change SHALL be counted, not listed. A `--verbose` option SHALL list every
file under its class. A path SHALL appear at most once in the change output,
with its most significant action. Each preserved file SHALL be reported
once, in a review block, together with its `.nogging-new` sibling. Each
forced overwrite SHALL be reported once, together with its `.orig` backup.
Warnings SHALL be deduplicated. The grouping SHALL NOT change which files
are written.

#### Scenario: A fresh install is summarized

- **WHEN** `init` runs in a fresh repository without `--verbose`
- **THEN** the output shows the header, one line per file class with counts, and no individual file list
- **AND** no path is reported twice

#### Scenario: An update with nothing to change is quiet

- **WHEN** `update` runs against an installation that already matches the package
- **THEN** the unchanged files are reported as a count only

#### Scenario: A preserved file is reported once

- **WHEN** `update` preserves a locally modified managed file
- **THEN** that file appears once, in the review block, with its `.nogging-new` path

#### Scenario: Verbose lists every file

- **WHEN** `init`, `update` or `remove` runs with `--verbose`
- **THEN** every affected path is listed once under its file class

### Requirement: init, update and remove end with explicit next steps

`init`, `update` and `remove` SHALL end with a numbered next-steps block.
Required steps SHALL come before optional ones, and optional steps SHALL be
marked as optional.

- After `init`, the steps SHALL cover resolving each verdict gap, running
  `./scripts/nogg doctor`, and starting the first plan through `/plan` or
  `./scripts/nogg worktree plan`. When units were rendered, they SHALL also
  cover enabling the sync timer and the orchestrator service, both marked
  optional.
- After `update`, the steps SHALL cover reviewing each `.nogging-new` file
  and running `doctor`. They SHALL omit the enable hint for a unit already
  reported enabled.
- After `remove`, the steps SHALL name each rendered unit to disable before
  the checkout is moved or deleted, and the shared entries left for manual
  review.

#### Scenario: init names the first plan

- **WHEN** `init` completes
- **THEN** the next steps include `./scripts/nogg doctor` and starting a plan with `/plan` or `./scripts/nogg worktree plan`
- **AND** the sync timer and orchestrator steps, if present, come after them and are marked optional

#### Scenario: update skips an enabled unit

- **WHEN** `update` runs and the sync timer is reported enabled
- **THEN** no step asks to enable the sync timer

#### Scenario: remove names the units to disable

- **WHEN** `remove` runs in a repository with rendered units
- **THEN** the next steps name each unit to disable before the checkout is removed

### Requirement: Bootstrap shows its plan and a closing summary in every mode

Before installing anything, `scripts/bootstrap` SHALL print a plan. The plan
names the target repository and the Nogging tag, and states for each tool
whether it is present (with its version), will be installed, or will be
upgraded. Apart from `init`'s own readiness check, it SHALL run
`scripts/nogg doctor` itself exactly once after `init`, show only that run's
failures and warnings, and name the file that holds the full report. Its exit status SHALL remain `doctor`'s. It SHALL end with a
plain-text closing summary in both modes. The summary lists what was
installed or upgraded, what was already present, and what was skipped. It
gives the login status of GitHub, Claude Code and Codex from read-only
checks, and next steps that match the installer's. It SHALL never read or
print a credential. Its platform refusal SHALL NOT name a release number.

#### Scenario: The plan precedes any install

- **WHEN** `scripts/bootstrap` runs on a supported machine missing some tools
- **THEN** it prints each tool's planned action before any install command runs

#### Scenario: A non-interactive run ends with a summary

- **WHEN** `scripts/bootstrap --non-interactive` completes
- **THEN** it prints the closing summary, including any tool that is not logged in and the command to log in

#### Scenario: doctor runs once

- **WHEN** `scripts/bootstrap` installs the payload
- **THEN** apart from `init`'s readiness check, bootstrap invokes `scripts/nogg doctor` exactly once
- **AND** only that run's failures and warnings are shown inline, with the full report written to a named file
