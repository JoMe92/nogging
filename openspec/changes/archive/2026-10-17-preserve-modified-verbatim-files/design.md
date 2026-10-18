## Context

See proposal.md for source [GitHub issue #165](https://github.com/JoMe92/nogging/issues/165).
Research examined `bin/cli.js`, `bin/lib/manifest.js`, `bin/lib/install.js`, `bin/lib/fsops.js`, `bin/lib/merge.js`, `bin/lib/remove.js`, `scripts/cli.test.sh`, and `scripts/installed-diagnostics.test.sh`.

In Nogging develop, `bin/lib/manifest.js` assigns all tool files (`scripts/nogg`, hooks, profiles, prompts, rules, reference docs) to the `verbatim` or `docs` classes. On `init` and `update`, `install.copyVerbatim()` and `install.copyDocs()` invoke `fsops.copyFile()` and `fsops.copyDir()`. `fsops.copyFile()` compares `dest` to `src` byte-for-byte; if different, it overwrites `dest` unconditionally.

In consumer repositories, operators legitimately customize files such as `.codex/rules/nogging.rules` (e.g. relaxing local commands) and `.nogging/launch-prompts/orchestrator.md` (e.g. tuning prompt instructions). When running `npx github:JoMe92/nogging update`, these local edits are silently clobbered with only an undifferentiated `overwrite <path>` log line. No hash record of what was previously installed exists, no `.orig` backup is made, and no conflict warning is printed.

## Goals / Non-Goals

### Goals

- Introduce `.nogging/installed-manifest.json` tracking the SHA-256 digest of every verbatim and doc file written.
- Provide a deterministic three-way comparison (`cur`, `next`, `recorded`) on `update` and idempotent re-`init`.
- Support seamless, backward-compatible upgrades from older installations lacking a manifest by referencing bundled historical release baselines (v2.1.0, v2.2.0).
- Preserve locally modified files by default: retain the local file, write upstream content to `<file>.nogging-new`, and print a prominent warning.
- Support `--force` on `update` (and `init`): back up the local file to `<file>.orig` before overwriting.
- Show conflict and preservation states distinctly in `--dry-run` and installer summary reports.
- Provide `scripts/nogg doctor` diagnostics warning of pending `<file>.nogging-new` files.
- Keep all tests completely offline, deterministic, and runnable on GitHub Actions runners without network or real tmux servers.

### Non-Goals

- No interactive three-way merge resolution or patch conflict markers during non-interactive updates.
- No changes to scaffold files (`.nogging/config.json`) or foreign merge files (`.claude/settings.json`, `CLAUDE.md`, `AGENTS.md`) which already have custom preservation rules.
- No remote network fetch or external registry calls during installation or update.

## Decisions

### 1. Manifest format and schema versioning (PVE-001)

Store the installation manifest at `.nogging/installed-manifest.json`.
Schema:
```json
{
  "manifest_version": 1,
  "nogging_version": "2.2.0",
  "files": {
    ".codex/rules/nogging.rules": "<sha256>",
    ".nogging/launch-prompts/orchestrator.md": "<sha256>",
    "scripts/nogg": "<sha256>"
  }
}
```
- `manifest_version`: Integer (currently `1`).
- `nogging_version`: String package version generating the manifest.
- `files`: Deterministically sorted dictionary mapping repo-relative POSIX paths to lowercase SHA-256 hex digests.
- File coverage: every file in `manifest.verbatim`, every recursive child file in `manifest.verbatimDirs`, and every file in `manifest.docs`.
- New module `bin/lib/manifest-store.js` provides pure, testable functions for reading, writing, computing digests, and comparing manifests.

### 2. Three-way comparison and file write semantics (PVE-002)

In `bin/lib/fsops.js` and `bin/lib/install.js`, replace the naive `copyFile` byte equality check with three-way state evaluation for verbatim and doc targets:
- `cur`: Current target file content on disk.
- `next`: Upstream source file content from package.
- `recorded`: SHA-256 digest from existing `.nogging/installed-manifest.json` (or resolved baseline).

Semantics:
1. Destination does not exist:
   - Action: `create`. Write `next` to destination.
2. `sha256(cur) === sha256(next)`:
   - Action: `unchanged`. Do not touch disk.
3. `sha256(cur) !== sha256(next)`:
   - If `sha256(cur) === recorded`:
     - Clean upstream update (local file is untouched since install).
     - Action: `update`. Overwrite destination with `next`.
   - If `sha256(cur) !== recorded`:
     - Local modification detected!
     - **Default mode**: Preserve `cur`. Write `next` to `<destination>.nogging-new`. Action: `preserve`. Emit warning: `locally modified file preserved: <path> (upstream written to <path>.nogging-new)`.
     - **Force mode (`--force`)**: Back up `cur` to `<destination>.orig`. Overwrite destination with `next`. Action: `force-overwrite`. Emit warning: `locally modified file overwritten (--force): <path> (backup saved to <path>.orig)`.

Under `--dry-run`:
- Perform all hash evaluations without writing any files (`destination`, `.nogging-new`, `.orig`, or `installed-manifest.json`).
- Render change log entries with distinct tags: `preserve`, `overwrite`, `create`, `update`, `unchanged`.

### 3. Backwards compatibility for legacy un-manifested installations (PVE-003)

For repositories initialized by Nogging releases prior to this change, no `.nogging/installed-manifest.json` exists on disk.
- Ship bundled baseline digests for prior releases in `bin/lib/baselines.js` (including v2.1.0 and v2.2.0).
- When reading the manifest on `update` or re-`init`:
  - If `.nogging/installed-manifest.json` exists, use it.
  - If missing, inspect `.nogging/config.json`'s `nogging_version`. Look up that version's baseline digests.
  - If a file matches the baseline for that recorded version, it is verified unmodified from that release and updates cleanly.
  - If the version is unknown or the file matches no baseline for that version, check all bundled release baselines. If it matches any recognized release baseline, treat it as an unmodified older file and update cleanly.
  - If the file matches no known baseline and differs from `next`, conservatively treat it as locally modified (preserve local file, write `.nogging-new`, warn). This guarantees zero silent loss of user modifications even on the very first update from an un-manifested release.
- On successful run, always write `.nogging/installed-manifest.json` with the resulting state.

### 4. CLI options and report formatting (PVE-003)

In `bin/cli.js`:
- Add `--force` to `parseArgs(argv)`.
- Update usage text explaining `--force` ("Overwrite locally modified verbatim files on update (backs up to <file>.orig)").
- In `report(ctx)`, format preserved files and warnings clearly so the operator immediately knows which files require attention and where their upstream counterparts live.

### 5. Doctor diagnostics and removal cleanup (PVE-004)

In `scripts/nogg`:
- `doctor`: Scan the repository for `<path>.nogging-new` and `<path>.orig` files.
- If any `.nogging-new` file exists, print:
  `WARN  locally modified file has pending upstream update: <path> (review <path>.nogging-new and reconcile)`
  Warnings are advisory and do not cause `doctor` to exit non-zero.
- If `.nogging/installed-manifest.json` exists, optionally check if any verbatim file differs from manifest without a `.nogging-new` file and surface as an informational NOTE.
In `bin/lib/remove.js`:
- Remove `.nogging/installed-manifest.json` and any leftover `.nogging-new` / `.orig` files when removing the Nogging payload.

### 6. Test discipline and validation (every task)

All tests must run offline, without network access, without contacting any real tmux server, and without external dependencies:
- PVE-001: Unit tests for manifest serialization, digest calculation, and baseline lookups.
- PVE-002: Regression tests for clean updates, local modifications preserved as `.nogging-new`, `--force` with `.orig`, and `--dry-run` display.
- PVE-003: Backward-compatibility tests verifying un-manifested v2.2.0/v2.1.0 upgrades (unmodified files update cleanly with no warnings; modified files are preserved as `.nogging-new`).
- PVE-004: Doctor diagnostic assertions verifying warnings on `.nogging-new`, and removal tests verifying manifest cleanup.
- PVE-005: Packaging and CLI integration tests in `scripts/cli.test.sh` ensuring `npm pack` includes new helper files and all installer tests pass on standard GitHub runners.
- PVE-006: Documentation and link consistency verification.

## Dependencies and parallel lanes

Branches use `<prefix>/preserve-modified-verbatim-files`. A lane reuses its branch only after its predecessor is integrated into `develop`. The prefix distinguishes concurrent worktrees, not the semantic commit type.

| Task | Complexity | Depends on | Branch prefix | Owned files |
| --- | --- | --- | --- | --- |
| PVE-001 Manifest schema & baselines | standard | none | `feat/` | `bin/lib/manifest-store.js`, `bin/lib/baselines.js`, new `scripts/manifest-store.test.sh` |
| PVE-002 Local modification preservation | complex | PVE-001 | `fix/` | `bin/lib/fsops.js`, `bin/lib/install.js`, new `scripts/manifest-update.test.sh` |
| PVE-003 Legacy upgrade & CLI --force | standard | PVE-002 | `fix/` | `bin/cli.js`, `bin/lib/install.js`, new `scripts/manifest-legacy-upgrade.test.sh` |
| PVE-004 Doctor diagnostics & removal | standard | PVE-002 | `feat/` | `scripts/nogg` (doctor), `bin/lib/remove.js`, new `scripts/manifest-doctor.test.sh` |
| PVE-005 End-to-end & package tests | standard | PVE-003, PVE-004 | `test/` | `package.json`, `scripts/cli.test.sh`, `scripts/installed-diagnostics.test.sh` |
| PVE-006 Operator documentation | routine | PVE-005 | `docs/` | `docs/installation.md`, `docs/operating-model.md`, `docs/failure-recovery.md` |

Explicit edges (`child <- blocker`):
- PVE-002 <- PVE-001
- PVE-003 <- PVE-002
- PVE-004 <- PVE-002
- PVE-005 <- PVE-003
- PVE-005 <- PVE-004
- PVE-006 <- PVE-005

PVE-001 starts immediately.
Once PVE-002 completes and integrates, PVE-003 (CLI/legacy upgrade) and PVE-004 (doctor diagnostics/remove) can run in parallel by separate Lead Agents.
PVE-005 integrates full CLI packaging and regression coverage.
PVE-006 finishes with operator documentation.

## Risks / Trade-offs

- **Risk**: Leftover `.nogging-new` files could accumulate if operators ignore installer warnings.
  - **Mitigation**: `scripts/nogg doctor` explicitly surfaces pending `.nogging-new` files with a prominent `WARN`, and `update` reports next steps.
- **Risk**: Incomplete historical baselines for un-manifested legacy versions could cause false `.nogging-new` preservations on first update.
  - **Mitigation**: Pre-calculate complete sha256 baselines for releases v2.1.0 and v2.2.0 in `bin/lib/baselines.js`. Any file matching either release updates cleanly without false warnings.
- **Risk**: File permissions (mode 0755 for executables like `scripts/nogg`) on `.nogging-new`.
  - **Mitigation**: Write `.nogging-new` with the same file mode (executable if source is executable) so operators can test the incoming upstream script directly if desired.

## Migration Plan

- The change is strictly additive and non-destructive.
- Existing repositories running `init` or `update` will automatically gain `.nogging/installed-manifest.json`.
- Unmodified files are updated cleanly as before.
- Locally customized files (e.g. `.codex/rules/nogging.rules`, `.nogging/launch-prompts/orchestrator.md`) are automatically protected from being overwritten, with upstream updates saved to `<file>.nogging-new`.
- Operators wishing to overwrite can pass `npx github:JoMe92/nogging update --force`.
