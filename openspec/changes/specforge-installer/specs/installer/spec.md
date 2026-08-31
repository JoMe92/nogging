## Purpose

The installer capability lets any git repository adopt and later refresh the
SpecForge operating structure from one command, without hand-copying files or
editing hard-coded paths, while never disturbing planning or execution state
that the target repository owns.

## ADDED Requirements

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
- **Rendered files** (the systemd sync service and timer) SHALL be generated
  with the target repository's absolute path and a per-repository unit name.

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

### Requirement: Installer reports an unusable hook path

When the target repository has `core.hooksPath` set so that Git will not read
`.git/hooks`, the installer SHALL warn that the two SpecForge git hooks
(`pre-commit`, `commit-msg`) will not run, rather than failing silently.

#### Scenario: core.hooksPath diverts Git hooks

- **WHEN** `init` runs in a repository whose `core.hooksPath` points outside `.git/hooks`
- **THEN** the installer completes
- **AND** it prints a warning that the `pre-commit` and `commit-msg` boundary hooks are not active
