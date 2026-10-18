## 1. README and the installer output spine (docs/ and feat/)

- [x] TASK-RRI-001 [standard] Per design Decision 2: rewrite README.md for newcomers: intro, Quick Guide, Install (bootstrap, then npx init), Use it day to day (plan, launch a Lead, watch and steer, close out), then the reference sections. Keep banner, badge, pinned-tag rule, a shorter safety warning and the v2.2.0 pins. v3.0.0 is a public release: drop 'pre-public release candidate' from the README and invert the matching assertion in scripts/nogging-identity.test.sh (absent, not required); the Project status and audience section instead notes that target repositories where agents run with full access stay private, and to read the safety warning before enabling --full-access or background services. Move the CI table to CONTRIBUTING.md. Check: new scripts/readme-structure.test.sh (also asserts no 'pre-public'/'release candidate' and the private-repository note); existing README suites; scripts/test. Branch docs/.

- [x] TASK-RRI-002 [standard] Per design Decision 3: add bin/lib/preflight.js, run first in init and update (also --dry-run): required and optional tools with fix hints; advisory, with timeouts, no network, exit status and writes unchanged; add it to package.json files. Check: new scripts/installer-preflight.test.sh (PATH stubs); scripts/package-manifest.test.sh; scripts/test. Branch feat/.

- [x] TASK-RRI-003 [standard] Per design Decision 4: add bin/lib/report.js: a header, changes grouped by file class with counts, each path once, unchanged files counted, new --verbose, one review block for preserved and forced files, deduplicated warnings. Check: new scripts/installer-output.test.sh; cli and manifest-legacy-upgrade suites adjusted for wording only; scripts/test. Branch feat/ (after TASK-RRI-002).

- [x] TASK-RRI-004 [standard] Per design Decision 5: numbered next steps after init, update and remove; ready verdict points to /plan or worktree plan; gaps deduplicated, no internal commands, a fix line each; npx doctor ends with the same verdict and exit status; update docs/acceptance.md step 3. Check: new scripts/installer-next-steps.test.sh; acceptance.sh and release-smoke-test matching unchanged; scripts/test. Branch feat/ (after TASK-RRI-003).

## 2. Bootstrap and changelog (fix/ and chore/, start at once)

- [x] TASK-RRI-005 [standard] Per design Decision 6: scripts/bootstrap prints a side-effect-free plan block, runs doctor itself once and shows only FAIL/WARN, and ends with the same plain-text summary in both modes (tools, read-only login status, next steps); no stale 2.0.x wording; POSIX sh, same flags. Check: new scripts/bootstrap-summary.test.sh; bootstrap-wizard and compatibility suites; scripts/test. Branch fix/.

- [x] TASK-RRI-006 [standard] Per design Decision 7: backfill CHANGELOG.md [Unreleased] with every user-visible change since v2.2.0, upgrade notes, and the three BREAKING bullets with their migrations; no version heading. Check: new scripts/changelog-format.test.sh (structure, BREAKING only in a major bump); the Bead note maps each change to its bullet; scripts/test. Branch chore/.

## 3. Consistency and release (test/, then chore/)

- [ ] TASK-RRI-007 [standard] Per design Decision 8: align docs/installation.md and CLI help with the final installer and bootstrap output; prerequisites equal the preflight table; pin assertions read package.json; docs/releasing.md step 4 names scripts/bootstrap. Check: new scripts/install-surface-consistency.test.sh and scripts/release-pins.test.sh; scripts/test. Branch test/.

- [ ] TASK-RRI-008 [routine] Per design Decision 9: docs/releasing.md steps 2-5 for 3.0.0: changelog bullets for this change, cut [Unreleased] to [3.0.0], package.json and lock to 3.0.0, every install pin to v3.0.0; commit chore(release): prepare v3.0.0 with the Bead token; never tag or release. Check: scripts/release-check 3.0.0 all OK, tag not yet existing; release-pins, changelog-format and scripts/test. Branch chore/ (after TASK-RRI-006).

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` = A depends on B): 003<-002, 004<-003, 007<-001, 007<-004, 007<-005, 008<-001, 008<-005, 008<-006, 008<-007. TASK-RRI-001, 002, 005 and 006 have no dependency and can start at once on four distinct branch prefixes. Branches are `<type>/release-readme-installer`, with lanes from design.md *Dependencies and parallel lanes*: docs/ 001; feat/ 002-004; fix/ 005; chore/ 006 then 008; test/ 007. A lane's next task reuses the prefix only after the previous branch is integrated and deleted. Each task's full contract is its design Decision plus the requirements of the capability specs in this change.

## Execution contract

The Main Worker claims every task and implements it only in its own allocated worktree on its lane branch. Before allocating a dependent worktree, verify that every prerequisite execution commit is integrated into develop; Bead closure alone is not enough. Follow design Decision 1 for every test: no network, no Dolt or bd, no running tmux server, no real systemctl or loginctl, and no new runtime dependency. Run each task's named checks. Then commit with a Conventional subject ending in the real Bead token, push the lane branch and open the pull request against develop. Only then run bd close and scripts/nogg task-done, and append the SHA and evidence to the Bead. A Codex Lead needs --full-access or --profile trusted to reach the shared Dolt server. Agents never hand-edit OpenSpec. Discoveries carry the discovery label and prose. Tagging, pushing the tag, the GitHub Release and release artifacts stay with the Orchestration Agent; nobody signs human acceptance.
