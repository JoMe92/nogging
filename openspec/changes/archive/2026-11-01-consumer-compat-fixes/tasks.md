## 1. Consumer compatibility fixes (GitHub issue #382, points 1 and 6)

- [ ] TASK-CCF-001 [standard] [~12 loc: below the 400-line range; one shared pattern in two files, a split leaves no testable half] A Beads issue ID token with a lower-case prefix passes the commit-msg hook and is seen by the LIMBO check.
  Per design Decision 1 and the requirement on the token prefix. Change `bead_token` in scripts/hooks/commit-msg and `LIMBO_TOKEN_RE` in scripts/nogg to the same prefix class `[A-Za-z][A-Za-z0-9]*`, keeping the suffix `[0-9a-z]+`, and reword the hook's refusal text from "lower-case/digit id" to say that the prefix may be of either case and the id is lower-case or digits. Update the pattern quoted in docs/architecture.md (the `commit-msg` section) and add a CHANGELOG.md [Unreleased] line. Tests: scripts/hooks/commit-msg.test.sh gains `[myproject-5nql]` accepted, `[SPEC-gjw]` still accepted, `[bead-XXX]`, `[BEAD-XXX]` and `[]` refused, first and red (medium, hook run on a temporary message file); scripts/nogg.test.sh gains a LIMBO case with a lower-case Bead ID reported as `LIMBO: myproject-... committed in` next to the existing upper-case case (medium, temporary repository). Check: scripts/hooks/commit-msg.test.sh and the LIMBO cases of scripts/nogg.test.sh (`scripts/test --only scripts/hooks/commit-msg.test.sh scripts/nogg.test.sh`). Branch fix/.

- [ ] TASK-CCF-002 [standard] [~25 loc: below the 400-line range; placeholder values in five shipped files, no behaviour to split] The shipped usage author, fixture identities and permissions template carry neutral placeholders that a release scan does not report.
  Per design Decisions 2 and 3 and the requirement on shipped placeholders. Replace `usage@nogging.local` with `usage@nogging.bot` in scripts/lib/token_usage_store.py (the Dolt `init --email` and the commit `--author`) and scripts/lib/token_usage_sync.py (`AUTHOR` and the `user.email` config). Replace the fixture addresses in scripts/pre-rebase-guard.test.sh, scripts/worktree-workflow.test.sh and scripts/agent-routing.test.sh with one neutral roster-domain address (`agent@nogging.bot`), and read the other scripts/*.test.sh for any further value of the same kinds, listing in the Bead note what was found and what was left. In templates/claude/orchestrator-permissions.example.json replace the example home path in the comment with the unexpanded placeholder form, keeping `HOME` and `<repo>`. Add a CHANGELOG.md [Unreleased] line. Tests: scripts/lib/token_usage_store_test.py and token_usage_sync_test.py gain one assertion each that the recorded Dolt author or sync commit author is `usage@nogging.bot`, first and red (medium, temporary Dolt store and repository); scripts/orchestrator-permissions-template.test.sh already refuses absolute host paths and must pass unchanged (small); the three fixture suites must pass unchanged (medium). Check: scripts/lib/token_usage_store_test.py, scripts/lib/token_usage_sync_test.py, scripts/orchestrator-permissions-template.test.sh, scripts/pre-rebase-guard.test.sh, scripts/worktree-workflow.test.sh and scripts/agent-routing.test.sh (`scripts/test --only` with those files). Branch fix/.

## Dependency contract

Explicit Beads edges, not task order, govern execution. Tasks 001 and 002 are independent:
they touch no common file except CHANGELOG.md [Unreleased], where the later one rebases
onto develop and keeps both lines. No dependency edge is wired.

Branches are `fix/consumer-compat-fixes-token` for 001 and `fix/consumer-compat-fixes-placeholders`
for 002, one per task so that neither waits for the other.

## Execution contract

A task's first line is its Bead title. Its full slice is that line plus the indented
paragraph under it, the design Decisions it names, and the matching requirements in
specs/. The Main Worker claims each task and implements it only in its own allocated
worktree, in several commits within the configured commit range. Write the tier
classification to the Bead note on every launch. Every suite is offline (no real agent,
shared tmux or herdr server, systemd or network). Test in stages: the tests of the
changed files while working, those tests plus lint before each commit, and the suites a
task names once per Bead. The full `scripts/test` is CI's job. Run a long command as one
blocking call (`./scripts/nogg run-quiet -- <command>`), never polled. Then push the
branch and open a pull request. No Bead note, commit message or fixture in this change
carries a private address or a home path.
