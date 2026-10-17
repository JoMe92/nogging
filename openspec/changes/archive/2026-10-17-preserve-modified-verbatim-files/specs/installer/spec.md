## MODIFIED Requirements

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

## ADDED Requirements

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
