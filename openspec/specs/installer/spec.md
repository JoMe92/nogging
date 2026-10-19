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

- **Tool and documentation files** (verbatim files in `manifest.verbatim`, `manifest.verbatimDirs`, and `manifest.docs`) SHALL be copied verbatim. On routine `update` and idempotent re-`init`, verbatim files SHALL be overwritten only when their current content matches the recorded installation baseline or matches the new upstream content. When local modifications are detected, the installer SHALL NOT silently overwrite the local file; it SHALL preserve the local file, write the upstream content to `<file>.nogging-new`, and emit a warning. When `--force` is specified, the installer SHALL back up the local file to `<file>.orig` before overwriting.
- **Scaffold files** (`openspec/config.yaml`, `openspec/project.md`, `.nogging/config.json`, `.nogging/model-selection.json`) SHALL be written only when absent and SHALL NOT be overwritten (except items marked `onUpdate`).
- **Foreign files** (`.claude/settings.json`, `.codex/hooks.json`, `.gitignore`, `CLAUDE.md`, `AGENTS.md`) SHALL be merged idempotently, preserving existing unrelated content, and SHALL be created when absent.
- **Rendered files** (systemd service and timer units) SHALL be generated with the target repository's absolute path and a per-repository unit name.

#### Scenario: Scaffold file is preserved

- **WHEN** `init` runs in a repository that already has `openspec/project.md`
- **THEN** the existing `openspec/project.md` is left unchanged

#### Scenario: Tool file is refreshed

- **WHEN** `update` runs after a new release changed `scripts/nogg`
- **THEN** the repository's `scripts/nogg` is replaced with the released version

#### Scenario: Foreign file keeps unrelated content

- **WHEN** the installer merges into a `.claude/settings.json` that already contains unrelated hooks and settings
- **THEN** those unrelated hooks and settings remain intact after the merge

#### Scenario: Unmodified verbatim file is updated cleanly

- **WHEN** `update` runs and an installed verbatim file matches its recorded baseline hash while upstream has changed
- **THEN** the file is overwritten with the new upstream content
- **AND** the updated SHA-256 hash is recorded in the manifest

#### Scenario: Locally modified verbatim file is preserved by default

- **WHEN** `update` runs and an installed verbatim file differs from both its recorded baseline hash and the new upstream content
- **THEN** the existing local file is left unchanged
- **AND** the upstream version is written alongside as `<file>.nogging-new`
- **AND** the installer logs a warning naming the preserved file and the `<file>.nogging-new` path

#### Scenario: Locally modified verbatim file is overwritten with --force

- **WHEN** `update --force` runs and an installed verbatim file differs from its recorded baseline hash
- **THEN** the existing local file is copied to `<file>.orig`
- **AND** the file is overwritten with the new upstream content
- **AND** the installer logs a warning noting the backup path

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

The `update` action SHALL NOT modify `openspec/changes/**`, `openspec/project.md`, the `name` field of `.nogging/config.json`, or any file under `.nogging/state`, `.nogging/locks` or `.nogging/reports`. It SHALL preserve locally modified verbatim files unless `--force` is given, and SHALL update `.nogging/installed-manifest.json` with the current installed file digests.

#### Scenario: Update leaves changes and project context alone

- **WHEN** `update` runs in a repository with active OpenSpec changes and a customized `openspec/project.md`
- **THEN** every file under `openspec/changes/` is unchanged
- **AND** `openspec/project.md` is unchanged
- **AND** `.nogging/config.json` records the new installed version

#### Scenario: Update preserves local modifications alongside project state

- **WHEN** `update` runs in a repository with active OpenSpec changes, custom `.codex/rules/nogging.rules`, and a customized `.nogging/launch-prompts/orchestrator.md`
- **THEN** `openspec/changes/` and project configuration remain unchanged
- **AND** `.codex/rules/nogging.rules` and `.nogging/launch-prompts/orchestrator.md` retain their local modifications
- **AND** upstream counterparts are written to `.codex/rules/nogging.rules.nogging-new` and `.nogging/launch-prompts/orchestrator.md.nogging-new`

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

### Requirement: A standalone bootstrap script provisions the whole supported toolchain

Nogging SHALL provide `scripts/bootstrap`, a standalone shell script runnable
via `curl | bash` without requiring Node or any other Nogging dependency to
already be present. On a supported platform (Debian/Ubuntu-family Linux,
x86_64 or aarch64, per `docs/compatibility.md`), running it with nothing
pre-installed SHALL result in a working target repository — Node, `bd`,
Dolt, the Claude Code / Codex / OpenSpec CLIs, `git`, `tmux`, and `gh`
present at the versions `docs/compatibility.md` documents as validated, and
the Nogging payload installed via `init`.

#### Scenario: A fresh, supported machine reaches a working install

- **WHEN** `scripts/bootstrap` runs on a supported platform with none of the
  toolchain pre-installed
- **THEN** every tool `docs/compatibility.md` documents as required ends up
  installed at a version satisfying its documented baseline
- **AND** the target repository has the Nogging payload installed and
  `scripts/nogg doctor` reports it healthy

#### Scenario: An unsupported platform is refused up front

- **WHEN** `scripts/bootstrap` runs on a platform outside the supported set
- **THEN** it prints the supported-platform statement and exits non-zero
- **AND** it installs nothing

### Requirement: Bootstrap orchestrates each tool's own official, pinned installer

`scripts/bootstrap` SHALL install `bd` and Dolt via each project's own
official install script, referenced at an exact pinned release tag rather
than a "latest" alias, and SHALL install the Node-ecosystem CLIs
(`@anthropic-ai/claude-code`, `@openai/codex`, `@fission-ai/openspec`, and
`@earendil-works/pi-coding-agent` when `--with-pi` is given) via
`npm install -g <package>@<pinned-version>`. It SHALL NOT implement its own
binary download or checksum verification for `bd` or Dolt.

#### Scenario: bd and Dolt install from a pinned release tag

- **WHEN** `scripts/bootstrap` installs `bd` or Dolt
- **THEN** it fetches that project's own install script from a URL naming
  an exact release tag
- **AND** that URL does not resolve to a "latest" alias

#### Scenario: Node-ecosystem CLIs install at the pinned version

- **WHEN** `scripts/bootstrap` installs Claude Code, Codex, or the OpenSpec
  CLI
- **THEN** the `npm install -g` command names an exact pinned version for
  that package

### Requirement: Bootstrap is idempotent and version-aware

Re-running `scripts/bootstrap` on a machine where every tool already
satisfies its pinned baseline SHALL change nothing and SHALL report each
tool as already satisfied, rather than reinstalling unconditionally. A tool
present but outside the satisfying range SHALL be upgraded to the pin.

#### Scenario: A second run on an already-provisioned machine is a no-op

- **WHEN** `scripts/bootstrap` runs a second time on a machine it already
  fully provisioned, with nothing changed in between
- **THEN** it makes no installation changes
- **AND** it reports every tool as already satisfying its pin

#### Scenario: An out-of-range tool is upgraded to the pin

- **WHEN** `scripts/bootstrap` finds a tool installed at a version outside
  the documented baseline's satisfying range
- **THEN** it installs the pinned version over it

### Requirement: Bootstrap's version pins cannot silently drift from the documented baseline

A test SHALL verify that every version `scripts/bootstrap` pins matches the
corresponding entry in `docs/compatibility.md`'s version table, and SHALL
fail when any pin disagrees with the documented baseline.

#### Scenario: A pin mismatch fails the test

- **WHEN** `scripts/bootstrap`'s pinned version for a tool does not match
  `docs/compatibility.md`'s documented baseline for that tool
- **THEN** the pin-consistency test fails, naming the mismatched tool

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

### Requirement: Installed user documentation is complete

The installer SHALL deliver every user guide referenced from installed
documentation, including the Claude, Codex, and Pi integration guidance. It
SHALL NOT install repository-internal research, conversation exports, or
historical acceptance reports as user documentation.

#### Scenario: An installed documentation link is followed

- **WHEN** a user follows any relative link from a document installed under `docs/nogging/`
- **THEN** its target is installed at the referenced path

### Requirement: Users can identify, update, roll back, and remove an installation

The CLI SHALL report its released version and the documentation SHALL provide
safe, explicit procedures for updating to a pinned release, rolling back to a
prior release, and removing Nogging-owned files and hook entries without
deleting target-owned OpenSpec changes, Beads data, configuration, or unrelated
agent settings.

#### Scenario: A user requests the installed tool version

- **WHEN** the version command or option is invoked
- **THEN** it prints the same semantic version recorded in the package

#### Scenario: A user removes Nogging

- **WHEN** the documented removal procedure is followed
- **THEN** Nogging-owned executables and injected configuration are removed or identified for removal
- **AND** target-owned planning and Beads state remain preserved

### Requirement: Platform support is explicit and test-backed

The installer SHALL declare the minimum supported versions of Node.js, Python,
Git, Bash, OpenSpec, Beads, and Dolt, plus which operating systems,
architectures, service managers, and agent CLIs are supported, experimental,
or unsupported. CI and acceptance SHALL exercise every combination claimed as
supported or explicitly document why a manual test supplies the evidence.

#### Scenario: A user checks compatibility before installation

- **WHEN** a user reads the compatibility documentation
- **THEN** they can determine whether their operating system, architecture, runtime versions, service manager, and chosen agent path are supported

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

### Requirement: Every installed session runtime helper is refreshed together

Nogging init and update SHALL install executable session launch and log-writer helpers from the same distribution as scripts/nogg. Update SHALL repair missing and stale helpers while preserving target-owned planning, Beads and unrelated configuration; remove SHALL remove only Nogging-owned helpers.

#### Scenario: Repair a partial older installation

- **WHEN** update runs in a repository missing either helper
- **THEN** both current executable helpers are installed and target-owned files are unchanged

#### Scenario: Consumer test portability

- **WHEN** the installed test runner runs with minimal supported configuration
- **THEN** tests use local fixtures and do not require Nogging maintainer changes or explicitly present defaulted keys

### Requirement: The installer maintains an installed-files manifest

`init` and `update` SHALL write `.nogging/installed-manifest.json` recording the SHA-256 digests of all verbatim and documentation files installed by Nogging. The manifest SHALL declare schema version 1 and the package version.

#### Scenario: Fresh install generates installed-manifest.json

- **WHEN** `init` runs in a fresh repository
- **THEN** `.nogging/installed-manifest.json` is created
- **AND** it contains SHA-256 digests for all verbatim tool files, directory contents, and reference docs
- **AND** entries are sorted deterministically

#### Scenario: Idempotent re-run leaves manifest intact

- **WHEN** `init` or `update` runs again without upstream or local file changes
- **THEN** the file content and manifest remain identical

### Requirement: The installer upgrades legacy installations without an existing manifest

When `update` or re-`init` runs in a repository installed by an earlier Nogging version lacking `.nogging/installed-manifest.json`, the installer SHALL evaluate existing files against known upstream baselines for earlier releases (including v2.1.0 and v2.2.0). Unmodified files matching known release baselines SHALL be upgraded cleanly, whereas files matching neither known baselines nor the new upstream content SHALL be preserved as locally modified.

#### Scenario: Clean upgrade from legacy release without manifest

- **WHEN** `update` runs in a repository installed with v2.2.0 that has no `.nogging/installed-manifest.json` and no local modifications
- **THEN** all files update cleanly without false conflict warnings
- **AND** `.nogging/installed-manifest.json` is created with the new file digests

#### Scenario: Modified file in legacy release is detected and preserved

- **WHEN** `update` runs in a repository installed with v2.2.0 lacking a manifest, where `.codex/rules/nogging.rules` has local edits
- **THEN** `.codex/rules/nogging.rules` is preserved
- **AND** `.codex/rules/nogging.rules.nogging-new` is written with a warning
- **AND** `.nogging/installed-manifest.json` is generated

### Requirement: Doctor reports pending upstream updates

`scripts/nogg doctor` SHALL check for unresolved `<file>.nogging-new` and `<file>.orig` artifacts in the repository. When any `<file>.nogging-new` is detected, it SHALL emit a warning advisory instructing the operator to review the diff and reconcile the local file.

#### Scenario: Doctor warns of pending upstream updates

- **WHEN** `scripts/nogg doctor` runs in a repository containing `.codex/rules/nogging.rules.nogging-new`
- **THEN** it prints a `WARN` line identifying the pending update
- **AND** it does not exit non-zero solely because of the warning

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
