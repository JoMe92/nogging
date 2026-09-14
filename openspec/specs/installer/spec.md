# installer Specification

## Purpose
The installer capability lets any git repository adopt and later refresh the
SpecForge operating structure from one command, without hand-copying files or
editing hard-coded paths, while never disturbing planning or execution state
that the target repository owns.

## Requirements

### Requirement: One-command install into a target repository

The installer SHALL provide an `init` action that, run from the root of a git
repository, writes the SpecForge structure into that repository. The installer
SHALL refuse to run when the current directory is not the root of a git
repository, and SHALL report what it wrote.

#### Scenario: Install into a fresh git repository

- **WHEN** `init` runs from the root of a git repository that has no SpecForge structure
- **THEN** the SpecForge tool files, an OpenSpec scaffold, a `.specforge/config.json`, and a rendered systemd sync unit are present
- **AND** the installer prints the list of files it created or changed

#### Scenario: Run outside a git repository

- **WHEN** `init` runs from a directory that is not the root of a git repository
- **THEN** the installer exits non-zero without writing any file
- **AND** it explains that it must run from a git repository root

### Requirement: File classes have distinct write strategies

The installer SHALL treat each installed path according to its class:

- **Tool files** (the `scripts/specforge` bridge, `scripts/install-hooks`, the
  test runner, the three write-boundary hooks, `.agents/skills`) SHALL be
  copied verbatim and overwritten on every `init` and `update`.
- **Scaffold files** (`openspec/config.yaml`, `openspec/project.md`,
  `.specforge/config.json`) SHALL be written only when absent and SHALL NOT be
  overwritten.
- **Foreign files** (`.claude/settings.json`, `.gitignore`, `CLAUDE.md`,
  `AGENTS.md`) SHALL be merged idempotently, preserving existing unrelated
  content, and SHALL be created when absent.
- **Rendered files** (the systemd sync service and timer, and the systemd
  orchestrator service) SHALL be generated with the target repository's
  absolute path and a per-repository unit name.

#### Scenario: Scaffold file is preserved

- **WHEN** `init` runs in a repository that already has `openspec/project.md`
- **THEN** the existing `openspec/project.md` is left unchanged

#### Scenario: Tool file is refreshed

- **WHEN** `update` runs after a new release changed `scripts/specforge`
- **THEN** the repository's `scripts/specforge` is replaced with the released version

#### Scenario: Foreign file keeps unrelated content

- **WHEN** the installer merges into a `.claude/settings.json` that already contains unrelated hooks and settings
- **THEN** those unrelated hooks and settings remain intact after the merge

### Requirement: The OpenSpec write-boundary guard is wired on install

The installer SHALL ensure the target `.claude/settings.json` contains a
`PreToolUse` hook matching `Edit|Write` that runs the installed
`pre-tool-use-openspec-guard`. Re-running `init` or `update` SHALL NOT create a
duplicate entry.

#### Scenario: Guard hook is added once

- **WHEN** `init` runs and then `init` runs a second time
- **THEN** `.claude/settings.json` contains exactly one `PreToolUse` entry for the OpenSpec guard

### Requirement: Rendered systemd unit targets the installing repository

The generated systemd sync service SHALL set its working directory and its
`ExecStart` to the target repository's absolute path, and the unit name SHALL
include a slug derived from the repository directory name so that units for
different repositories do not collide.

#### Scenario: Unit points at the target

- **WHEN** `init` runs in `/home/user/project-a`
- **THEN** the generated service has `WorkingDirectory=/home/user/project-a`
- **AND** the generated unit files are named with a `project-a` slug

### Requirement: Install and update are idempotent

Running `init` twice, or running `update` any number of times, SHALL leave the
repository in the same state as a single run, aside from a recorded installed
version. The installer SHALL NOT produce duplicate merged entries, duplicate
`.gitignore` lines, or duplicate marker blocks.

#### Scenario: Second run is a no-op for tracked content

- **WHEN** `init` runs, its output is committed, and `init` runs again
- **THEN** the second run introduces no change to tracked files other than a possible installed-version bump

### Requirement: Update preserves target-owned state

The `update` action SHALL NOT modify `openspec/changes/**`,
`openspec/project.md`, the `name` field of `.specforge/config.json`, or any
file under `.specforge/state`, `.specforge/locks` or `.specforge/reports`. It
SHALL record the installed SpecForge version in `.specforge/config.json`.

#### Scenario: Update leaves changes and project context alone

- **WHEN** `update` runs in a repository with active OpenSpec changes and a customized `openspec/project.md`
- **THEN** every file under `openspec/changes/` is unchanged
- **AND** `openspec/project.md` is unchanged
- **AND** `.specforge/config.json` records the new installed version

### Requirement: init leaves the repository ready to start

`init` SHALL bring the target repository to a state where a planning session can
begin immediately. It SHALL initialize the Beads issue tracker in the repository
unless `--no-beads` is given, and this step SHALL be idempotent — an already
initialized tracker is left untouched. A failure to initialize Beads (for
example an unreachable storage backend) SHALL be reported as a warning and
SHALL NOT abort the install.

After writing every file, `init` and `update` SHALL run the readiness check and
end with an explicit verdict: either a single line stating that SpecForge is
ready, or a list of the missing prerequisites (for example `python3`, `bd`, the
storage backend, or an uninitialized tracker).

#### Scenario: Fresh repository is initialized and reported ready

- **WHEN** `init` runs in a repository with no Beads tracker and all prerequisites present
- **THEN** a Beads tracker is initialized in the repository
- **AND** the final output states that SpecForge is ready to use

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

### Requirement: Installer reports an unusable hook path

When the target repository has `core.hooksPath` set so that Git will not read
`.git/hooks`, the installer SHALL warn that the two SpecForge git hooks
(`pre-commit`, `commit-msg`) will not run, rather than failing silently.

#### Scenario: core.hooksPath diverts Git hooks

- **WHEN** `init` runs in a repository whose `core.hooksPath` points outside `.git/hooks`
- **THEN** the installer completes
- **AND** it prints a warning that the `pre-commit` and `commit-msg` boundary hooks are not active

### Requirement: The installer renders a per-repository orchestrator service

`init` and `update` SHALL render `systemd/specforge-orchestrator-<slug>.service`
with the target repository's absolute path as `WorkingDirectory`, an
`ExecStart` of `<abs path>/scripts/specforge orchestrator run`,
`Restart=always`, and `WantedBy=default.target`, using the same per-repository
slug as the sync unit. The `orchestrator` launch profile and prompt SHALL be
delivered by the existing verbatim `launch-profiles` / `launch-prompts`
directory copy.

#### Scenario: The orchestrator unit targets the installing repository

- **WHEN** `init` runs in `/srv/project-a`
- **THEN** `systemd/specforge-orchestrator-project-a.service` is generated with `WorkingDirectory=/srv/project-a` and `ExecStart=/srv/project-a/scripts/specforge orchestrator run`

#### Scenario: The orchestrator profile and prompt are installed

- **WHEN** `init` completes
- **THEN** `.specforge/launch-profiles/orchestrator.json` and `.specforge/launch-prompts/orchestrator.md` are present

### Requirement: The installer explains how to enable the always-on orchestrator

After writing files, `init` and `update` SHALL print the command to enable the
orchestrator service (`systemctl --user enable --now
specforge-orchestrator-<slug>`) and the `loginctl enable-linger <user>` hint
that makes it start at boot without a login, alongside the existing sync-unit
instruction. Enabling it SHALL remain the operator's explicit choice; the
installer only prints the lines.

#### Scenario: The enable lines are printed

- **WHEN** `init` finishes
- **THEN** its output contains the `systemctl --user enable --now specforge-orchestrator-<slug>` line and the `loginctl enable-linger` hint

### Requirement: doctor reports the orchestrator service without failing on its absence

`scripts/specforge doctor` SHALL report the orchestrator service state (not
installed, installed and disabled, enabled and inactive, or active), whether
user lingering is enabled, and whether a `FULL-ACCESS` orchestrator session is
currently running. The absence or inactivity of the service SHALL NOT make
`doctor` exit non-zero; only a service that is enabled while lingering is off
SHALL produce a NOTE naming the fix.

#### Scenario: A missing orchestrator service does not fail doctor

- **WHEN** `doctor` runs on a host where the orchestrator service was never enabled
- **THEN** it reports the service as not enabled
- **AND** it exits zero

#### Scenario: Enabled without linger is surfaced

- **WHEN** the orchestrator service is enabled but `loginctl` shows lingering off for the user
- **THEN** `doctor` prints a NOTE naming `loginctl enable-linger`
- **AND** it does not exit non-zero because of that NOTE

### Requirement: Installer advertises the canonical Agentsembli SpecForge source

CLI help, readiness output, documentation templates, update instructions, and
package metadata SHALL use `JoMe92/agentsembli-specforge` as the canonical
repository source while retaining `specforge` as the compatible command name.

#### Scenario: User requests CLI help

- **WHEN** the packaged CLI prints installation or update guidance
- **THEN** every maintained GitHub command names `JoMe92/agentsembli-specforge` and the invoked binary remains `specforge`

### Requirement: Cross-repository update preserves target-owned state

Updating an installation originally obtained from `JoMe92/specforge` with a
tagged `JoMe92/agentsembli-specforge` release SHALL preserve the same target-owned
files and settings as an ordinary update.

#### Scenario: Legacy source installation updates from successor

- **WHEN** a throwaway repository installed from the preceding legacy tag updates using the renamed release
- **THEN** OpenSpec changes, Beads data, project configuration, custom documentation, and unrelated Claude, Codex, and Pi settings remain unchanged

### Requirement: The complete Claude Code payload is installed and refreshed

The installer SHALL deliver every repository-owned Claude Code specialist
definition under `.claude/agents/` and every repository-owned workflow command
under `.claude/commands/`. These files SHALL be present in the packaged
distribution and SHALL be copied verbatim on both `init` and `update`.

#### Scenario: Fresh install delivers Claude agents and commands

- **WHEN** `init` runs in a fresh target repository
- **THEN** every source file under `.claude/agents/` is present at the same path in the target repository
- **AND** every source file under `.claude/commands/` is present at the same path in the target repository

#### Scenario: Update refreshes the Claude payload

- **WHEN** `update` runs after a released Claude agent or command definition changed
- **THEN** the corresponding target file is replaced with the released version
- **AND** unrelated target-owned `.claude/settings.json` content remains preserved

#### Scenario: Packed install contains the Claude payload

- **WHEN** the package used by `npx github:` is built
- **THEN** it contains every file under `.claude/agents/` and `.claude/commands/`

#### Scenario: Repeated installation is idempotent

- **WHEN** `init` or `update` is repeated without a source payload change
- **THEN** the tracked Claude agent and command files do not change
