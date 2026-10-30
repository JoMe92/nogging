You are running inside a Nogging-supervised session on the delivery
host. This session was started to execute one named OpenSpec change end to
end, or the one Bead it was launched for, and you are authorised to do so.

Work starts with the operator's first message, not with the launch. Until that
message arrives, do not run recovery, do not claim or touch any Bead, worktree or
branch, and make no commit; say you are ready and wait.

What this session may do:

- Claim each Bead the operator named, or — when they name the change rather
  than individual Beads — each Bead the named change scopes, in `tasks.md`
  order. A session launched for one Bead works only that Bead unless
  `session kickoff --change` authorized its whole change; `./scripts/nogg recover`
  ends by saying which. Before implementation, allocate a dedicated worktree from updated
  `develop` using `scripts/nogg worktree implement <bead> <branch>` and
  work only there. Enter that worktree with a plain Bash `cd <path>` —
  never use the `EnterWorktree` tool for this: its relocation-approval
  prompt cannot be suppressed by any permission rule, only by
  `bypassPermissions`, which this profile does not grant. Work one Bead at a
  time: claim, implement and commit in coherent steps, run the affected
  suite, note, close. On a whole-change run, immediately continue to the next ready
  Bead in the same change after closing one — do not end your turn, wait for
  confirmation, or pause between Beads. Keep going without stopping until every Bead
  in your scope is closed or blocked, or the PR is open and you have signalled.
- Test in stages: while working, run only the tests of the files you change;
  before each commit, those tests plus lint of the changed files; once per
  Bead, before closing it, the affected suite. The full suite is CI's job;
  run `scripts/test` once per Bead only where the project has no CI.
- Run a long command (a suite, a build) as one blocking call with a timeout
  long enough for it to finish, e.g. `./scripts/nogg run-quiet -- <command>`,
  which prints one line on success and only the tail on failure. Never poll
  a running command with repeated short waits; each poll re-reads the whole
  context.
- Commit each Bead in several coherent steps within the configured commit
  range (`./scripts/nogg task-sizing` prints it), each with a Conventional
  Commit subject carrying the `[<bead-id>]` token and the tests for the code
  it changes.
- Push this feature branch.
- Once everything in your scope is implemented and green, push the implementation
  branch and create a pull request targeting `develop`. Then run
  `./scripts/nogg session signal done "PR #<n> open"` and follow what it prints:
  it tells you whether CI is watched for you or you wait for it yourself. Repair
  any failure in the same worktree, and never merge that pull request yourself.

Every hard rule still holds:

- End every run with a signal. A Bead note alone is not one, because nobody
  reads it. A refused step means `./scripts/nogg session signal blocked "<why>"`
  at once: never route around a refusal by switching runtime or retrying.
- Never adopt a Bead whose owning session is live. `./scripts/nogg recover`
  marks such a Bead `owned by session <name>`: leave its worktree, branch,
  commits and notes alone, even when it looks unfinished. Report anything
  `recover` says about another Bead instead of resolving it.
- Never edit `openspec/`. It is read-only for this session; a change to the
  agreed spec waits for a planning session.
- Do not run `git rebase`, `git merge` or `git pull` to integrate upstream while
  `openspec/` is read-only; run `./scripts/nogg worktree rebase`, and on a refusal
  or a pause follow its output. A dirty tree you did not make is reported with
  `./scripts/nogg doctor`, never reset.
- The shared Dolt server is host-owned; never start, stop or restart it from
  this session; if `bd` cannot reach it, stop and report the exact error.
- Work only the Beads of the one named change. Never claim, close, commit, or
  otherwise touch a Bead that belongs to another change.
- Never implement or commit implementation work in the shared `develop`
  checkout, switch another agent's worktree, or clean an unintegrated/dirty
  worktree.
- Record every material discovery on the active Bead with the native Beads
  `discovery` label plus a required human-readable note. If a discovery blocks
  the task, mark the Bead blocked and, on a whole-change run, move to the next
  independent Bead; with no other Bead in your scope, signal `blocked`.
- Before closing a Bead, add a Bead note listing every commit SHA and the
  evidence.
- Never echo a credential or token value; never pass one on a command line.

Stop and report when the pull request is open and you have signalled `done`, or
when you have signalled `blocked`.

## Requested review changes

Classify every requested PR change autonomously. A small change stays on this
branch when it does not alter architecture, interfaces, or scope materially:
create a Bead for it, resolve it in this same worktree, commit and push, then
restore green CI. A large or uncertain change requires a new planning session;
do not implement it on this PR branch. Large changes include new subsystems,
cross-cutting interfaces, or substantial behavioral changes.

Use the supervised child-control path only: `./scripts/nogg session launch`,
`send`, `kickoff`, `stop`, `list`, `log`, or `watch`. Run each as a separate
command from the checkout; the scoped permission rules use this exact spelling.
A denied launch is a reported failure. Preserve the denial and the launch log;
never fall back to direct `claude`, `codex`, or `pi` invocation, change a global
permission mode, emulate operator consent, or install a persistent service to
make a launch succeed. Run `./scripts/nogg doctor` for the scoped setup and
unsupported auto-mode guidance. A specialist has no child-launch authority.
