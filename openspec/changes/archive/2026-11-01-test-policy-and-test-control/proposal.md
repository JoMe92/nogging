## Why

Repositories that use Nogging must not end up where LoadCompass is. Measured
read-only on 2026-10-31, that seven-day-old repository holds 88k test lines
against 156k production lines, and 60 % of its commits add tests. Its backend
suite went from 6 minutes (1,438 tests, 10-27) to 33 minutes (2,758 tests, 10-31)
and a full local run with web tests, type check and build takes 45 to 60 minutes
and more. The same suite is 2 to 3 times slower while four Leads share the host.

The rules were right and nothing checked them. The repository says "the full
suite is CI's job", but its workflow runs only on pull requests to `main` and is
missing from `main`, so CI never runs a test, and no nightly timer exists. Leads
ran the full suite locally anyway: at least 48 full backend runs and 76 web runs
since 10-26, 28 of them on 10-31 alone.

Nogging has the same gap. Test guidance is prose in `templates/agents-block.md`.
Nothing verifies that CI really runs tests, and plans themselves prescribe full
runs: 4 of 78 `Check:` fields in `openspec/changes/*/tasks.md` say `scripts/test`.
This repository's own full suite took 5,754 seconds on the delivery host in
discovery SPEC-la92. The research report that goes with this change
(https://claude.ai/artifact/KVwL2yATpsLjPwKi5P9MR8) adds the outside evidence:
agents touch tests twice as often as humans and add more mocks, yet leave error
paths untested in 81 to 86 % of pull requests; coverage overstates value; agents
game tests when spec and tests conflict; and procedural TDD instructions alone
raised regressions, while giving the agent the code-to-test map lowered them.

Nogging therefore ships the policy and the mechanics that enforce it. The Product
Owner approved phases 1 and 2 for implementation now, with phase 3 recorded as a
follow-up. The orchestrator cuts release v3.6.0 after implementation.

## What Changes

**Phase 1: prevent the LoadCompass outcome.**

- **Shipped test policy.** `docs/testing-policy.md`, installed and refreshed by
  `init` and `update` as `docs/nogging/testing-policy.md` and referenced from the
  agents and Claude blocks. It says what to always test, what not to test, which
  level fits a change, that mocks belong only at real process boundaries, that
  expensive setup happens once per run, and that tests do not sleep. It stays
  short and names no framework.
- **`nogg test changed|commit|bead|full`.** One entry point. Commands come from a
  new `testing.stages` block, budgets from `testing.budgets` with a plain
  over-budget report, output goes through `run-quiet`, and the slowest tests are
  surfaced. `full` is refused unless it is a release, a nightly run or carries an
  explicit, recorded reason. A host-wide slot limit
  (`testing.max_parallel_heavy`) caps heavy runs across repositories. Agent blocks
  and launch prompts switch from `scripts/test` to the stages.
- **CI reality check.** `doctor` verifies through `gh`, quietly degrading offline,
  that test jobs actually ran on the integration branch recently, and says so
  when they did not.
- **Nightly fallback.** `init` and `update` render a systemd user timer that runs
  the full stage once a night on an idle host when no CI runs tests. A failure
  reaches the orchestrator through the session-wake digest.
- **Test metrics.** Runtime per stage, tests and test lines added, slowest tests,
  tests deleted or skipped, in the per-Bead token report and in a new
  `nogg test report` with a daily trend. `doctor` adds a NOTE when suite runtime
  grows sharply week over week or a stage exceeds its budget.

**Phase 2: stop growth at the source.**

- **Task format.** A `Tests:` field names the scenarios and their size.
  `nogg validate` and `materialize` reject a new task whose `Check:` demands the
  full suite, and `task_sizing` gains a per-Bead test budget.
- **Integrity check.** A rule script that CI and `nogg test bead` share flags
  deleted tests, new skips and removed assertions that carry no justification.
- **Reviewer checklist.** The `code-reviewer` specialist reviews test value:
  duplicates, mirror tests, wrong level, source-text assertions.

**Phase 3 is a recorded follow-up**, not part of this change: `nogg test
prune-candidates` (per-test coverage overlap weighted by runtime) and
mutation-confirmed deletion. See design Decision 16.

## Capabilities

### New Capabilities

- `test-policy`: the shipped policy document, how agents and reviewers receive
  it, the task format that names tests, and the integrity check.
- `test-control`: the `nogg test` stages, budgets, the full-suite lock, heavy
  slots, the CI reality check, the nightly fallback and test metrics.

### Modified Capabilities

- `installer`: renders the per-repository nightly units, ships the policy, and
  tells an upgrading repository that the `testing` defaults apply.

## Impact

- **New code:** `scripts/lib/testing_stages.py`, `testing_runs.py`,
  `testing_diff.py`, `testing_ci.py`, `testing_nightly.py`, `testing_report.py`,
  `scripts/check-test-integrity`, `templates/systemd/nogg-nightly.*.tmpl`,
  `docs/testing-policy.md`, `docs/test-control.md`.
- **Changed code:** `scripts/nogg` (subcommands and doctor sections, `task_sizing`,
  `validate`, `materialize`, dispatch), `scripts/test` (`--only`, `--timings`),
  `scripts/lib/session_wake.py`, `scripts/lib/token_usage_report.py`,
  `bin/lib/{manifest,install,nextsteps}.js`, `package.json`,
  `.github/workflows/nogging-validate.yml`.
- **Guidance:** `AGENTS.md`, `CLAUDE.md`, `templates/agents-block.md`,
  `templates/claude-block.md`, launch prompts, specialist definitions, planning
  prompts for every runtime, `docs/operating-model.md`, `docs/commands.md`,
  `docs/configuration.md`.
- **Existing consumers:** an `update` of a repository with no `testing` block
  keeps working with safe defaults (design Decision 14). `scripts/test` keeps its
  behaviour without arguments and Nogging's self-tests stay excluded from it.
- **New state, all local and gitignored:** `.nogging/state/testing/`, in the main
  checkout.
