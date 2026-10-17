## Why

Source: [GitHub issue #165](https://github.com/JoMe92/nogging/issues/165).
The Nogging installer (`bin/cli.js update` and re-running `init`) silently overwrites locally modified verbatim files (such as `.codex/rules/nogging.rules` and `.nogging/launch-prompts/orchestrator.md`). The only indicator is an undifferentiated `overwrite <path>` entry in the installer change log, identical to routine upstream refreshes. No checksum manifest, three-way comparison, `.orig` backup, prominent warning, or `--force` control exists today.

## What Changes

- Introduce `.nogging/installed-manifest.json` recording the SHA-256 digests of all files installed verbatim and documentation files.
- Support backward-compatible upgrades from installations lacking a manifest by providing historical baseline checksums (for releases v2.2.0 and v2.1.0) and conservatively protecting unrecorded deviations.
- Detect local modifications during `update` and re-`init`: when a file's current hash matches neither upstream's new content nor the recorded/baseline hash, treat it as locally modified.
- By default, preserve the locally modified file, write the new upstream content to `<file>.nogging-new`, and log a prominent warning.
- Add `--force` to `update` (and `init`), backing up the local file to `<file>.orig` before overwriting with the upstream version.
- Distinguish locally modified preservation and forced overwrite in `--dry-run` and installer summaries.
- Add diagnostic checks in `scripts/nogg doctor` to surface unresolved `<file>.nogging-new` files and locally modified files.
- Ensure `remove` cleans up the installed manifest and related artifacts cleanly.

## Capabilities

### Modified Capabilities

- `installer`: records installed checksums in `.nogging/installed-manifest.json`, detects local modifications on `update`, preserves user edits as `<file>.nogging-new` by default or backs up to `<file>.orig` with `--force`, supports backward-compatible upgrade without a prior manifest, and provides doctor diagnostics for pending upstream files.

## Impact

- `bin/cli.js`, `bin/lib/install.js`, `bin/lib/fsops.js`, `bin/lib/manifest.js`, `bin/lib/remove.js`, and new manifest helper modules under `bin/lib/`.
- `scripts/nogg` doctor command; existing installer tests (`scripts/cli.test.sh`, `scripts/installed-diagnostics.test.sh`) and new regression test suites.
- Documentation in `docs/installation.md`, `docs/operating-model.md`, and `docs/failure-recovery.md`.
- No new external runtime dependency or long-running service is introduced.

## Non-Goals

- No semantic three-way merge or interactive resolution prompt during non-interactive updates.
- No changes to Git repository commit hooks, planning lock mechanisms, or OpenSpec boundary guards.
- No changes to scaffold files (`.nogging/config.json`) or foreign merge targets (`CLAUDE.md`, `AGENTS.md`, `.claude/settings.json`) which already follow non-verbatim preservation policies.
- No implementation during planning; no git push, release tag, or human sign-off.
