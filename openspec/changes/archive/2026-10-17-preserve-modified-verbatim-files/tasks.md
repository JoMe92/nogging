## 1. Manifest store and baselines (feat/ lane)

- [x] TASK-PVE-001 [standard] Add manifest-store and historical release baselines for SHA-256 tracking of verbatim files per design Decision 1; implement serialization, digest calculation, and baseline lookups. Check: new scripts/manifest-store.test.sh, scripts/test. Branch: feat/preserve-modified-verbatim-files. No dependency.

## 2. Local modification detection and preservation (fix/ lane)

- [x] TASK-PVE-002 [complex] Implement three-way hash comparison in fsops and install to preserve locally modified verbatim files as .nogging-new by default per design Decision 2; support --dry-run reporting. Check: new scripts/manifest-update.test.sh, scripts/test. Branch: fix/preserve-modified-verbatim-files. Depends on TASK-PVE-001.

## 3. Backward compatibility and CLI options (fix/ lane)

- [x] TASK-PVE-003 [standard] Implement backward-compatible un-manifested upgrade and --force flag with .orig backups in CLI per design Decisions 3-4; update report output. Check: new scripts/manifest-legacy-upgrade.test.sh, scripts/test. Branch: fix/preserve-modified-verbatim-files. Depends on TASK-PVE-002.

## 4. Diagnostics and removal (feat/ lane, parallel with 3)

- [x] TASK-PVE-004 [standard] Add doctor warnings for pending .nogging-new files and manifest cleanup in removal helper per design Decision 5. Check: new scripts/manifest-doctor.test.sh, scripts/installed-diagnostics.test.sh, scripts/test. Branch: feat/preserve-modified-verbatim-files. Depends on TASK-PVE-002.

## 5. End-to-end installer coverage (test/ lane)

- [x] TASK-PVE-005 [standard] Integrate end-to-end installer tests and package files list validation in cli.test.sh per design Decision 6; verify offline runner stability. Check: scripts/cli.test.sh, scripts/installed-diagnostics.test.sh, scripts/test. Branch: test/preserve-modified-verbatim-files. Depends on TASK-PVE-003 and TASK-PVE-004.

## 6. Documentation (docs/ lane)

- [x] TASK-PVE-006 [routine] Document installed-manifest tracking, .nogging-new preservation workflow, --force, and doctor warnings in installation and recovery guides per design Migration Plan. Check: scripts/installation-docs.test.sh, scripts/test. Branch: docs/preserve-modified-verbatim-files. Depends on TASK-PVE-005.

## Dependency contract

Materialize explicit Beads edges (`child <- blocker`):
- PVE-002 <- PVE-001
- PVE-003 <- PVE-002
- PVE-004 <- PVE-002
- PVE-005 <- PVE-003
- PVE-005 <- PVE-004
- PVE-006 <- PVE-005

No cross-change dependency is required. Task order and change association create no implicit blocking edges. Branch prefixes and file ownership are defined in design.md; same-prefix tasks are sequential.

## Execution contract

Every task includes design Decision 6 and its mapped capability scenarios. Only the Main Worker claims execution Beads, allocates isolated worktrees, validates, closes and immediately runs task-done, commits implementation plus the mechanical tick with its Bead-ID token, and records SHA/evidence, following AGENTS.md and current operator delivery authority. Execution agents do not hand-edit OpenSpec. Verify prerequisite commits are integrated into develop before allocating dependent worktrees. All tasks suit Codex or Antigravity Leads. Planning itself authorizes no implementation, push, release, or human sign-off.
