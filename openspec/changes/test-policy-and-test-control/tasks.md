# Tasks: test policy and test control

Dependencies are wired explicitly in Beads per design Decision 17, not by this order.
TPC-001, TPC-002 and TPC-003 can run at once, then TPC-004 and TPC-006, then TPC-005,
and TPC-007 last. Every task adds its entry under `## [Unreleased]` in CHANGELOG.md,
lists any new runtime module in bin/lib/manifest.js and package.json, ships no new test
file, and keeps new modules named `testing_*.py`, never `test_*.py` (Decision 1). Tests
follow the task's `Tests:` field and docs/testing-policy.md once it exists. No Check here
runs the whole suite: name the suites in the task, and leave the rest to CI.

## 1. Foundations (parallel)

- [ ] TASK-TPC-001 [standard] [~520 loc] The test policy ships, reviewers check test value, and new tasks cannot demand the full suite.
  Per design Decisions 9 and 14 and the test-policy requirements on the policy, the code
  reviewer, the task format, the full-suite Check and the test budget. Write
  docs/testing-policy.md: always test, do not test, level per change, mocks only at real
  process boundaries, expensive setup once per run with the template-database example, no
  real sleeps; short and framework-neutral. Ship it through the `docs` manifest class, and
  add it to docs/README.md and docs/_config.yml. Add the test-value checklist to
  .claude/agents/code-reviewer.md. In scripts/nogg add a task-format check outside
  mapping_audit: parse `Check:` and `Tests:` from open_task_blocks, refuse a full-suite
  Check on an unmapped open task in `nogg validate` and in `materialize` before the first
  `bd create`, print a NOTE for a mapped task and for a missing or sizeless `Tests:` field.
  Add `bead_test_lines` to TASK_SIZING_DEFAULTS. Require `Tests:` and define the three sizes
  in .claude/commands/plan.md, .codex/prompts/plan.md, .pi/prompts/plan.md,
  templates/antigravity/skills/nogging-plan/SKILL.md, .nogging/launch-prompts/planning.md,
  docs/operating-model.md (Task sizing), docs/configuration.md, docs/first-change.md and
  docs/glossary.md. Do not edit the agent blocks; TASK-TPC-004 references the policy there.
  Tests: small Scenarios "A new task demands the full suite", "A named suite passes", "An
  approved task is left alone", "A task without the field", "A documentation task" and "The
  budget prints" against the pure parser; medium `validate` and `materialize` on a temporary
  repository with a stubbed bd, proving no Bead is created; medium the prompt parity check.
  Check: scripts/nogg-materialize.test.sh, scripts/planning-docs.test.sh,
  scripts/runtime-guidance-docs.test.sh, scripts/docs-site.test.sh,
  scripts/package-manifest.test.sh. Branch docs/.

- [x] TASK-TPC-002 [complex] [~850 loc] `nogg test changed|commit|bead|full` runs every stage under budgets, the full lock and host-wide slots, and leaves a record.
  Per design Decisions 1 to 8 and 14 and the test-control requirements from "One entry
  point" through "A malformed testing block". Add pure scripts/lib/testing_stages.py (the
  whole `testing` block with every key of Decision 2, stage resolution, change sets,
  placeholder expansion, budget and lock decisions) and scripts/lib/testing_runs.py (record
  schema 1, rotation, JUnit and timings parsing, slowest tests). Wire a `test` subparser
  into scripts/nogg with `--bead`, `--base`, `--release`, `--nightly` and `--allow-full`,
  reusing run_quiet and run_quiet_denied as they are. Implement the slots of Decision 7, and
  write records to the main checkout's state, resolved through canonical_repository_state.
  Add `--only` and `--timings` to scripts/test, read before test-env.sh, and leave its
  no-argument behaviour alone. Add the `testing` block to templates/nogging-config.json with empty `stages`, give
  this repository its own stages in .nogging/config.json (`scripts/test --only {test_files}`
  and `scripts/test --timings {timings}`), add the doctor WARNs, and the one-line `update`
  notice in bin/lib/install.js next to the session_dispatch one. Write docs/test-control.md
  and ship it, and document `test` in docs/commands.md in `nogg --help` order and in
  docs/configuration.md. Exit codes: 77 refused, 75 slot timeout.
  Tests: small every row of the Decision 3 and Decision 6 tables, placeholder expansion
  including "A file name cannot become an option", budget arithmetic, JUnit and timings
  parsing including "A broken result file"; medium `nogg test` on temporary repositories for
  "A command that needs files has none", "A denied command stays denied", "A repository with
  no CI", "An explicit exception" and "A Lead claims a release"; medium real flock across two
  processes for "Three heavy runs on two slots", "A crashed holder" and "The slot directory
  is unusable"; medium the update notice.
  Check: new scripts/nogg-test.test.sh and scripts/lib/testing_stages_test.py,
  scripts/lib/testing_runs_test.py, scripts/run-quiet.test.sh, scripts/selftest-scope.test.sh,
  scripts/cli.test.sh, scripts/docs-site.test.sh, scripts/package-manifest.test.sh. Branch feat/.

- [ ] TASK-TPC-003 [standard] [~480 loc] One integrity rule flags deleted tests, new skips and removed assertions, and this repository's CI enforces it.
  Per design Decision 10 and the test-policy requirement on the integrity rule. Add pure
  scripts/lib/testing_diff.py: parse a unified diff, use TEST_PATH_RE by importing it, hold
  the language-neutral tables of test definitions, skip and xfail forms and assertion forms,
  and return tests added, tests deleted, skips added and assertion deltas over a whole range,
  so moved tests net out. Add scripts/check-test-integrity <base> [--enforce], reading
  `Test-Integrity:` trailers from the range, like scripts/check-branch-name. Ship both, and
  add the executable to the manifest. Document the trailer in docs/operating-model.md and
  docs/test-control.md if TASK-TPC-002 has landed, else in docs/operating-model.md alone. Add
  one `invariants` step to .github/workflows/nogging-validate.yml running the script with
  --enforce against origin/$GITHUB_BASE_REF as this Bead's last, separate commit. A Lead's
  HTTPS push of that file is refused for lack of the `workflow` scope: then record a
  discovery, run `session signal blocked` and leave the commit for the orchestrator to push
  over SSH, as for SPEC-mmio. Do not widen any credential. The `nogg test` wiring lands in
  TASK-TPC-006.
  Tests: small the diff analyser on committed sample diffs in Python, TypeScript, Go, Rust and
  shell for each flag, plus "A rename is not a deletion"; medium the script on temporary
  repositories for "A test is deleted without justification" and "A justified removal passes".
  Check: new scripts/check-test-integrity.test.sh and scripts/lib/testing_diff_test.py,
  scripts/lib/token_usage_report_test.py, scripts/package-manifest.test.sh. Branch test/.

## 2. Guidance and CI evidence

- [x] TASK-TPC-004 [standard] [~650 loc] Agents work on the stages, and `doctor` proves whether CI really runs tests.
  Per design Decision 11 and the test-policy requirement on agents and the test-control
  requirement on doctor. Add pure scripts/lib/testing_ci.py and a thin refresh in scripts/nogg
  with the 10-second bound and the cache at .nogging/state/testing/ci-check.json, reading
  `testing.ci`; add its doctor section so `none` is a WARN, `stale` a NOTE, and `ran` or
  `unknown` print nothing. Switch every instruction from `scripts/test` to the stages, naming
  the policy: templates/agents-block.md, templates/claude-block.md, AGENTS.md, CLAUDE.md,
  .nogging/launch-prompts/autonomous.md and orchestrator.md, .claude/agents/backend-engineer.md
  and test-runner.md, docs/operating-model.md, README.md and docs/running-work-in-sessions.md.
  The rule becomes: `nogg test changed` while working, `nogg test commit` before each commit,
  `nogg test bead` once per Bead, and `nogg test full` only for a release, the nightly run or an
  explicit recorded reason. Add the integrity rule to the same text: weakening a test takes a
  `Test-Integrity: <reason>` trailer and a discovery note. Leave the "run scripts/test as
  acceptance" prohibition in the planning prompts as it is. Document the check in
  docs/test-control.md and docs/configuration.md.
  Tests: small every row of the Decision 11 table from captured `gh` JSON; medium doctor with a
  stubbed `gh` for "A workflow that never runs tests", "Offline", "A cached result" and "A red
  test job", and proving the exit code is unchanged; medium the guidance parity check for "A
  Lead reads its block".
  Check: new scripts/doctor-ci-check.test.sh and scripts/lib/testing_ci_test.py,
  scripts/runtime-guidance-docs.test.sh, scripts/agents-boundary.test.sh,
  scripts/install-surface-consistency.test.sh, scripts/docs-site.test.sh. Branch chore/.

## 3. Fallback and visibility

- [ ] TASK-TPC-005 [complex] [~650 loc] Where no CI runs tests, a nightly run on an idle host tests the integration branch, and a failure reaches the orchestrator.
  Per design Decision 12 and the requirements on the nightly run, the digest and the nightly
  units. Add templates/systemd/nogg-nightly.service.tmpl (`Type=oneshot`, `Nice=15`,
  `IOSchedulingClass=idle`, a start timeout that covers the full budget) and nogg-nightly.timer.tmpl
  (`OnCalendar=*-*-* 01..05:17:00`), add both to manifest.systemd and package.json, and name
  the timer in bin/lib/nextsteps.js as a service-plus-timer pair like the loop units. Add pure
  scripts/lib/testing_nightly.py for the gates, the idle decision and the digest item, and `nogg
  test nightly`: gates in Decision 12's order, fetch with the offline fallback, the retained
  `<main>-nightly` worktree, `testing.nightly.setup`, `nogg test full --nightly`, and
  nightly-last.json. Extend the `auto` lock with the 3-day record rule. Feed the record into the
  dispatch pass in scripts/nogg and add `nightly_failed` to scripts/lib/session_wake.py labels,
  not to URGENT_KINDS. Add the doctor WARN for a failed last run and the NOTE to enable the timer.
  Name the worktree in bin/lib/remove.js output. Document it in docs/test-control.md,
  docs/session-wake.md and docs/installation.md.
  Tests: small every gate in Decision 12 and the item's dedupe and clearing, "A failure" and "A
  later pass"; medium `nogg test nightly` on a temporary repository with a bare origin for "CI runs
  the tests", "The commit is already tested", "A busy host", "Offline" and "The shared checkout is
  untouched"; medium rendered units for "A consumer gains the units on update" and "No systemd".
  Check: new scripts/nogg-test-nightly.test.sh and scripts/lib/testing_nightly_test.py,
  scripts/session-dispatch.test.sh, scripts/lib/session_wake_test.py, scripts/cli.test.sh,
  scripts/installer-next-steps.test.sh, scripts/package-manifest.test.sh, and `systemd-analyze
  --user verify` on the rendered units where available. Branch feat/.

- [ ] TASK-TPC-006 [standard] [~620 loc] Test cost is visible per Bead and as a trend, and the bead stage runs the integrity check.
  Per design Decisions 10 and 13 and the requirements on test metrics and the bead stage. Add
  pure scripts/lib/testing_report.py for daily aggregation, medians, the week-over-week change,
  explicit full runs and budget misses. Add `nogg test report [--days N] [--json]` and `nogg test
  integrity [--base <ref>]`. Run the integrity rule at the end of `nogg test bead`, honouring
  `testing.integrity`, and check the `discovery` label through `bd` where it is reachable. Set
  `enforce` in this repository's .nogging/config.json. Print the `bead_test_lines` line in the
  `bead` stage. Extend token_usage_report.bead_view and render_bead_report with stage seconds,
  tests added, tests deleted and skips added through testing_diff, keeping every existing JSON
  field. Add the doctor NOTEs for trend, over budget and `--allow-full` from Lead sessions.
  Document it in docs/token-usage.md, docs/test-control.md and docs/commands.md.
  Tests: small aggregation and the trend rule for "A suite that grows", "Too few runs" and "No
  records yet" on fixture records; small bead_view with fixture commits; medium `nogg test report`
  on a temporary repository; medium `nogg test bead` for "A Bead above its test budget" and "The
  default in a consumer"; medium `nogg test integrity` with a stubbed bd for "A trailer without a
  discovery note".
  Check: new scripts/nogg-test-report.test.sh and scripts/lib/testing_report_test.py,
  scripts/lib/token_usage_report_test.py, scripts/packed-token-usage.test.sh,
  scripts/docs-site.test.sh. Branch perf/.

## 4. Proof

- [ ] TASK-TPC-007 [standard] [~90 loc: end-to-end proof only, no product behaviour] A packed install proves the whole change on an existing consumer with no `testing` block and on a configured one.
  Per design Decision 14 and the installer requirements. Add scripts/packed-test-control.test.sh:
  pack this tree, then install the previous release tag into a scratch repository with a plain
  scripts/*.test.sh, run `update`, and assert every row of the Decision 14 table: the notice
  appears once, the config is byte-identical, `doctor` keeps its exit code, `validate` passes
  with a mapped legacy `Check: scripts/test`, `nogg test changed|bead|full` behave as stated, and
  `scripts/test` still skips shipped self-tests. Then configure a `testing` block with a stub runner
  that writes JUnit and exceeds a budget, and assert the budget line, the slowest tests, the full
  refusal, a record, and `nogg test report`. Stub `gh`, `bd` and `systemctl`, and use no network.
  Fix what the proof finds in the Bead that owns it, through a discovery if that Bead is closed.
  Add the new page and commands to docs/README.md if any are missing. This Bead does not
  cut the release; the orchestrator does.
  Tests: large the two packed scenarios above, because the upgrade path cannot be shown smaller.
  Check: new scripts/packed-test-control.test.sh, scripts/packed-session-launch.test.sh,
  scripts/selftest-scope.test.sh, scripts/release-pins.test.sh. Branch test/.
