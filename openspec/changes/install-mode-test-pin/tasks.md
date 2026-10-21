## 1. Installer file mode (#263)

- [x] TASK-IMT-001 [standard] Per design Decisions 1-4, 9: fsops copyFile derives the mode from the packaged source for create, update, force, .nogging-new; repairs a matching file that lost the executable bit; .orig stays mode-preserving. Failing-first scripts/installer-file-mode.test.sh (packed v2.2.0-shaped install without the recorder). CHANGELOG Fixed. Check: that suite, cli, manifest-update, manifest-legacy-upgrade; scripts/test. Branch fix/. GitHub #263.

## 2. Fixture backend pin (#264)

- [ ] TASK-IMT-002 [standard] Per design Decisions 5-9: shipped scripts/lib/test-fixture-config.sh copy_host_config pins session_backend to tmux; switch worktree-workflow, nogg and the other herdr-failing suites of Decision 6 to it. Failing-first scripts/fixture-backend-pin.test.sh runs them under a herdr host config (test-agents.sh stubs). CHANGELOG Fixed. Check: that suite; scripts/test also with a herdr host config. Branch test/. GitHub #264.

## Dependency contract

No Beads dependency edges: TASK-IMT-001 and TASK-IMT-002 touch different code and different suites and can start at once on two distinct branch prefixes, `fix/install-mode-test-pin` for 001 and `test/install-mode-test-pin` for 002. Their only shared file is the `[Unreleased]` hunk of CHANGELOG.md; the task that lands second rebases over the first and keeps both bullets. Each task's full contract is its design Decisions plus the requirements of the capability specs in this change.

## Execution contract

The Main Worker claims each task and implements it only in its own allocated worktree on its lane branch. Follow design Decision 8 for every test: no network, no real codex, agy, claude, bd, Dolt, tmux or herdr, stubs only (scripts/lib/test-agents.sh where an agent binary is needed). Run each task's named checks, commit with a Conventional subject ending in the real Bead token, then run bd close and scripts/nogg task-done and append the SHA and evidence to the Bead. Agents never hand-edit OpenSpec. Discoveries carry the discovery label and prose. Nobody signs human acceptance.
