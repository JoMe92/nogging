# Execution log

<!-- nogg:SPEC-6y35:2026-10-21T13:41:35Z -->
- 2026-10-21T13:55:56+00:00 — SPEC-6y35 closed for TASK-IMT-002 (Bead closed at 2026-10-21T13:41:35Z).
  - implementation commits: 0610af0
  - Bead note:
    Planned 2026-10-21 in install-mode-test-pin (planning-id install-mode-test-pin; GitHub #264). Read only the mapped tasks.md line, design Decisions 5-9 and the test-isolation requirement. Complexity: standard. Branch: test/install-mode-test-pin. Failing-first scripts/fixture-backend-pin.test.sh; offline, scripts/lib/test-agents.sh stubs (CI has no codex/agy). The new helper must be shipped (manifest verbatim + package.json files). Independent of SPEC-b8wb (shared CHANGELOG [Unreleased] hunk only).
    tier standard; Claude entry (Codex weekly 90%, gate would deny); bug in shipped v3.0.0 (patch release v3.0.1)
    commit 0610af0; PR #266; fixture-backend-pin.test.sh 26/26 (herdr host config, offline stubs); 31 other converted/shipped suites (cli, manifest-*, installed-diagnostics, etc.) pass; full scripts/test left to CI. nogg worktree rebase refused (requester does not own checkout) but branch already on origin/develop. Discovery found during work: session-observability run_py inherited host config.

<!-- nogg:SPEC-b8wb:2026-10-21T13:34:35Z -->
- 2026-10-21T13:55:56+00:00 — SPEC-b8wb closed for TASK-IMT-001 (Bead closed at 2026-10-21T13:34:35Z).
  - implementation commits: 57cc9584b05e, 7cee9b78e110
  - Bead note:
    Planned 2026-10-21 in install-mode-test-pin (planning-id install-mode-test-pin; GitHub #263). Read only the mapped tasks.md line, design Decisions 1-4 and 9, and the installer capability requirements. Complexity: standard. Branch: fix/install-mode-test-pin. Failing-first scripts/installer-file-mode.test.sh; offline, no tmux/Dolt. Independent of SPEC-6y35 (shared CHANGELOG [Unreleased] hunk only; second to land rebases).
    tier standard; Claude entry (Codex weekly 90%, gate would deny); bug in shipped v3.0.0 (patch release v3.0.1)
    commit 7cee9b7; PR #265 (fix/install-mode-test-pin -> develop). Evidence: scripts/installer-file-mode.test.sh red on develop (recorder mode 664), green after fix (8 checks); cli, manifest-update (2 fixtures adjusted for repair semantics), manifest-legacy-upgrade, manifest-store, package-manifest, manifest-doctor pass. Report change: verbose report prints '(mode 0755)' for repairs. Full scripts/test left to CI (Pi loaded). nogg worktree rebase refused ('requester session does not own this checkout') but origin/develop had not moved, so no rebase was needed.

<!-- nogg:SPEC-6y35:2026-10-21T14:09:55Z -->
- 2026-10-21T14:29:22+00:00 — SPEC-6y35 closed for TASK-IMT-002 (Bead closed at 2026-10-21T14:09:55Z).
  - implementation commits: 41d7442a9d4b, 0610af0, ee45b3f
  - Bead note:
    Planned 2026-10-21 in install-mode-test-pin (planning-id install-mode-test-pin; GitHub #264). Read only the mapped tasks.md line, design Decisions 5-9 and the test-isolation requirement. Complexity: standard. Branch: test/install-mode-test-pin. Failing-first scripts/fixture-backend-pin.test.sh; offline, scripts/lib/test-agents.sh stubs (CI has no codex/agy). The new helper must be shipped (manifest verbatim + package.json files). Independent of SPEC-b8wb (shared CHANGELOG [Unreleased] hunk only).
    tier standard; Claude entry (Codex weekly 90%, gate would deny); bug in shipped v3.0.0 (patch release v3.0.1)
    commit 0610af0; PR #266; fixture-backend-pin.test.sh 26/26 (herdr host config, offline stubs); 31 other converted/shipped suites (cli, manifest-*, installed-diagnostics, etc.) pass; full scripts/test left to CI. nogg worktree rebase refused (requester does not own checkout) but branch already on origin/develop. Discovery found during work: session-observability run_py inherited host config.
    orchestrator 2026-10-21 16:02: PR #266 conflicted with merged #265 in CHANGELOG.md (both add a Fixed entry). Operator rebase paused in /home/jome/src/nogging-spec-6y35; reopened so a Lead merges both entries, finishes the rebase and force-pushes; close again after the push.
    commit 41d7442 (rebased onto develop ee45b3f, CHANGELOG conflict resolved keeping both Fixed entries, force-with-lease pushed to PR 266); changelog-format.test.sh and fixture-backend-pin.test.sh pass
