## 1. Fixes for the live acceptance findings

- [ ] TASK-SWF-001 [standard] [~330 loc: below the 400-line range; one cohesive limit slice, a split leaves no testable half] A Codex usage limit is read as `limit`, waited out and resumed once, never nudged.
  Per design Decisions 1 to 5 and the requirements on the Codex limit and on the limit wait. `last_turn` in scripts/lib/session_codex_delivery.py exposes the terminal error (string kind, 200-character message, timestamp, `None` otherwise). `resolve_state` and `classify_session_detail` give a rollout `limit` its slot beside event, herdr and pane; `CODEX_ADAPTER` gets the `hit your usage limit` patterns for both apostrophes, counted only with the idle composer and no `Working (` marker. Resolve the reset time against the error's local timestamp; carry `until` on the watch `limit` event and `limit_until` on the dispatch fact. `_limit_step` treats a rollout or Codex pane limit like an event limit, keys each resume on the error timestamp, replaces `until` from a newer error, and queues one `stuck` item for an unreadable reset. Update docs/session-wake.md, docs/using-with-codex.md and CHANGELOG.md [Unreleased]. Check: session-codex-*, session-signals and session-dispatch suites and the Python unit tests beside them, first and red, with a committed real-shape rollout excerpt and pane (no email, token or account detail): two passes send no nudge, one resume after the reset, a re-limited resume waits again, an unreadable reset queues one item. Branch fix/.

- [ ] TASK-SWF-002 [standard] [~90 loc: below the 400-line range; one extension constant and its test] Pi lifecycle emits wait 20 s for a slow `scripts/nogg` and never block Pi.
  Per design Decision 6 and the requirement on Pi lifecycle events. Raise `EMIT_TIMEOUT_MS` in .pi/extensions/nogging-lifecycle.ts from 3000 to 20000 with a comment giving the measured startup (1.3 s idle, 3.5 s at load 16) and why a retry is rejected; leave the 8000 ms guard check and `DRAIN_MS` as they are. Extend scripts/pi-lifecycle.test.sh with a fake `scripts/nogg` that takes 4 s to append (the event lands, Pi's handler returned first) and one that never exits (killed at the timeout, later events append in order, shutdown delayed by no more than the drain bound). Update docs/using-with-pi.md and CHANGELOG.md [Unreleased]. Check: pi-lifecycle suite first and red (keeps its skip-pass where Node cannot strip types), pi-guard and docs-site suites. Branch feat/.

- [ ] TASK-SWF-003 [standard] [~110 loc: below the 400-line range; one reducer used in two places] The newest run of each check decides red and green, and a superseded failure no longer counts.
  Per design Decision 7 and the requirement on the latest run of each check. Add the pure `_latest_check_entries(rollup)` next to `_check_outcome` in scripts/nogg and call it from `_observe_checks` (before sorting and the fingerprint) and `_pr_state_for_branch` (before the resolved test). Key by workflow and name for a check run and by context for a status; newest `startedAt`, then `completedAt`; ties and missing times keep the worse outcome; a malformed rollup stays `unknown`. Update docs/session-wake.md (the CI rows) and CHANGELOG.md [Unreleased]. Check: session-sweep-checks and session-dispatch suites, first and red, with committed rollup fixtures taken from PR #350 and PR #355 shapes (superseded failure, newer failure, shared commit, tie, pending newer, malformed). Branch refactor/.

## 2. Re-acceptance on the delivery host

- [ ] TASK-SWF-004 [standard] [~100 loc: below the 400-line range; a live acceptance report] Re-run the failed rows of the session-wake acceptance on the delivery host.
  Per design Decision 8. After 001 to 003 are integrated and the host runs them, write docs/acceptance/<date>-session-wake-fixes.md, unsigned with an empty Signed-off-by line, covering: the Codex limit from a replayed real rollout and pane (the limit cannot be forced), the Pi first turn under load, and a failed-then-passed check on one commit on a throwaway branch with no pull request left open. Record what was not shown. Never stop the shared tmux server or the orchestrator; restarting the orchestrator stays with the operator. Check: report committed, docs-site suite. Branch test/.

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` means A depends on B):
004<-001; 004<-002; 004<-003. Tasks 001, 002 and 003 are independent and can run in
parallel; each touches different code, and where scripts/nogg overlaps, rebase onto
develop and keep both sides.

Branches are `<type>/session-wake-fixes`, one prefix per task so that none waits for
another's branch: fix/ 001, feat/ 002, refactor/ 003, test/ 004. Before allocating a
dependent worktree, verify that every prerequisite execution commit is integrated into
develop; Bead closure alone is not enough.

## Execution contract

A task's first line is its Bead title. Its full slice is that line plus the indented
paragraph under it, the design Decisions it names, and the matching requirements in
specs/. The Main Worker claims each task and implements it only in its own allocated
worktree, in several commits within the configured commit range. Write the tier
classification to the Bead note on every launch. Every suite is offline (no real agent,
Dolt, bd, shared tmux or herdr server, systemd or network; private sockets; injected
clocks and openers). Test in stages: the tests of the changed files while working,
those tests plus lint before each commit, and the suites a task names once per Bead.
The full `scripts/test` is CI's job. Run a long command as one blocking call
(`./scripts/nogg run-quiet -- <command>`), never polled. Then push the branch and open
the pull request against develop. Only then run bd close and `scripts/nogg task-done`,
and append every SHA and the evidence to the Bead. Agents never hand-edit OpenSpec.
Discoveries carry the discovery label and prose. Fixtures and docs contain no email
address and no real key. Nobody signs human acceptance.
