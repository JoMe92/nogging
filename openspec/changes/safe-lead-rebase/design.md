## Context

Research baseline: develop `29b32ad`. Facts below were read from the code, not
inferred from the issue text.

- The fence. `scripts/openspec-sandbox` (host side, `supervise`) starts the
  session child in `unshare --user --mount`, bind-mounts every checkout root's
  `openspec/` read-only, exports `NOGG_OPENSPEC_FENCED=1` and
  `NOGG_TASK_DONE_SOCKET`, and keeps a **host-side broker thread** in the
  original mount namespace. Writes made by the broker through the ordinary host
  path are visible to the child because the child's mount is a bind of the same
  directory.
- The broker is closed on purpose: it accepts exactly `{bead_id, checkout}`,
  validates that `checkout` is a registered worktree root of the same
  repository, and calls `task_done` with `ROOT` swapped. No path, command or
  replacement text is accepted.
- `implementation_worktree()` writes `.nogging/state/worktrees/implementation--<id>.json`
  (`path`, `branch`, `base_ref`, `state`) and sets the `lead` persona identity as
  worktree-scoped git config. `cleanup_worktree()` already shows the safety
  pattern: clean tree, branch integrated, in-use check, no force.
- `recover_scan()` / `doctor()` already iterate worktree records read-only and
  print `NOTE`/attention lines; `repo_sync_state()` already knows how to find a
  linked worktree's git directory and rebase/merge/cherry-pick state.
- Git, not Nogging, fails: `git rebase`/`git checkout` write files in path order
  and abort on the first `EROFS`. Files sorted before `openspec/` are already
  written, the index and `HEAD` are not yet updated, and a failed checkout
  records no `rebase-merge/` or `rebase-apply/` directory. That is exactly the
  state in #241 and the reason neither `--abort` nor `reset` knows about it.

### Decision 1: CI test discipline

Every new suite builds a real git fixture in a temp dir: a bare `origin`, a
seeded repository with `develop`, a linked implementation worktree on a
conventional branch, and upstream commits that touch both code and
`openspec/changes/**/tasks.md` (plus a rename into `archive/`). No suite starts a
tmux or herdr server, runs `unshare` or a real mount, assumes a PID range, needs
Dolt or `bd` (stub `bd` where `claimed_bead` or a mapping is reached), or reads
live quota; each sources `scripts/lib/test-env.sh`. A suite that reaches
`session launch` sources `scripts/lib/test-agents.sh` (`use_agent_stubs`) so the
launch preflight passes with inert agent binaries. No suite relies on
`_is_legacy_mock`: any suite that drives launch, readiness or delivery code
asserts `not m._is_legacy_mock()` as the existing real-path suites do. A fenced
caller is simulated by `NOGG_OPENSPEC_FENCED=1` plus a Unix-socket broker thread
running the real handler (the pattern of `task-done-broker.test.sh`); read-only
failure of raw git is demonstrated with `chmod` only when the suite is not root,
and the half-applied state is otherwise **synthesised** by writing upstream blob
contents into the worktree without touching the index, so no suite depends on a
permission error. Each task's new suite fails first on current develop.

### Decision 2: The writer side runs the rebase; the Lead only asks

The process that can write `openspec/` is the one that must check files out. A
Lead cannot be given a writable `openspec/` (the fence is the point), and
"a human or the orchestrator does it by hand" is the failure being removed. So:

- **Unfenced caller** (operator, orchestrator, a trusted full-access session
  outside a fence): `nogg worktree rebase` runs the engine directly.
- **Fenced caller** (a Lead): the same command detects `NOGG_OPENSPEC_FENCED=1`,
  never runs git itself, and sends one closed request to the existing broker
  (Decision 6). The broker is host side, so it is the boundary-holding side. A
  fenced caller with no broker (an older launch) refuses with the hand-off
  below and changes nothing.

Rejected: lifting the read-only mount for the duration of a rebase (reopens the
whole boundary and cannot be proved closed again after a crash); a Lead-side
`git rebase` with `--no-checkout` or a sparse checkout that skips `openspec/`
(leaves the tree's `openspec/` stale and the index disagreeing, which later
looks like the very modification this change detects); merging instead of
rebasing (same write path, plus merge commits the branch rules do not expect);
a dedicated second broker socket (more surface than extending the closed one).

### Decision 3: Command surface and target resolution

`nogg worktree rebase [<record>] [--continue | --abort] [--allow-live-session]`.

- `<record>` is a filename under the canonical `.nogging/state/worktrees/`, as for
  `cleanup`. Omitted, the record whose `path` equals the caller's checkout root is
  used, so a Lead types `./scripts/nogg worktree rebase` in its worktree. Records
  are always read through the canonical state directory so a call from a linked
  worktree finds them.
- Only `kind: implementation` records are accepted. A planning record is refused
  with the reason: a planner's `openspec/` is writable and it rebases its own
  branch under the planning lock.
- Base is `origin/develop` after `git fetch origin develop`, the same ref
  `implementation_worktree` allocates from, never the local `develop`.
- Exit codes: 0 done or already up to date, 1 refused or failed with nothing
  changed, 3 paused on a code conflict (a real git rebase is in progress).

### Decision 4: Refusals, in order, before any write

1. The target is a registered implementation worktree (its record exists,
   `state: allocated`, `path` is in `git worktree list`, the directory exists).
2. `HEAD` is on `record.branch`: not detached, not `main`/`develop`.
3. No git operation in progress (`MERGE_HEAD`, `CHERRY_PICK_HEAD`, `BISECT_LOG`,
   `rebase-merge/`, `rebase-apply/`), except Nogg's own paused rebase, which is
   answered with "use `--continue` or `--abort`".
4. The working tree is completely clean (`git status --porcelain` empty,
   untracked files included; ignored files excluded). Otherwise the dirty paths
   are named and, if the classifier of Decision 7 finds a half-applied checkout,
   its recovery hint is printed. There is no auto-stash: the stash stack is shared
   across all worktrees and hides work.
5. No live supervised session other than the requester records this worktree as
   its working directory, unless `--allow-live-session` (an operator who has
   confirmed the Lead is parked). The requester is identified by
   `NOGG_SESSION_NAME`, passed in the broker request; the broker checks it against
   the session record. An agent could name another session, so this is an
   accident guard, not an authentication boundary (see Limitations).
6. The branch has no merge commits in `origin/develop..HEAD`; `git rebase` would
   flatten them silently.
7. `git fetch origin develop` succeeds and `origin/develop` resolves.

If `origin/develop` is already an ancestor of `HEAD`, print `already up to
date`, write nothing, exit 0.

### Decision 5: Mechanics and conflict policy

Engine order: write a journal `.nogging/state/rebase/<record-stem>.json`
(`branch`, `before`, `onto`, `requester`, `started_at`, `phase: running`) →
create `refs/nogg/rebase-backup/<branch>/<UTC-stamp>` at `before` → run `git -C
<worktree> rebase origin/develop` with `GIT_EDITOR=true`,
`GIT_SEQUENCE_EDITOR=true` and any `NOGG_OPENSPEC_FENCED` removed from the
environment → on success verify `origin/develop` is an ancestor of `HEAD`, the
tree is clean and no operation state remains, delete the journal and print the
new tip, the backup ref and the exact restore command (`git reset --hard
<before>` is printed **as information for the operator**, never executed).
Commits replayed keep the Lead identity because git reads the worktree-scoped
config of the worktree it runs in.

Conflicts are the decision the Product Owner asked to see explained:

- **Any conflicted path under `openspec/`** (or a rename into/out of it) →
  the engine runs `git rebase --abort`, verifies the tree equals `before` (same
  `HEAD`, clean), names the paths and refuses with exit 1. The Lead can neither
  see nor edit those paths and must not guess. Hand-off: the orchestrator or
  operator resolves it from an unfenced shell, or a planning session adjusts the
  upstream change. This is rare in practice: `task-done` ticks are single lines
  and git's rename detection carries a tick onto an archived `tasks.md`.
- **Conflicts only outside `openspec/`** → the real git rebase is left paused
  (valid state, `rebase-merge/` present), the journal moves to `phase: paused`,
  the conflicted paths are listed and the exit code is 3. The Lead edits the
  files in its own worktree, stages them (`git add` writes only the shared
  gitdir) and runs `worktree rebase --continue`; the engine reruns `git rebase
  --continue` on the writer side, because later replayed commits can still write
  `openspec/` paths. A new conflict pauses again; success finishes as above.
- `worktree rebase --abort` runs `git rebase --abort` on the writer side and
  verifies the tree equals `before`. `--continue` and `--abort` with no paused
  Nogg rebase refuse and change nothing.
- A crash mid-engine leaves the journal at `running` with no git state: `recover`
  reports it (Decision 7); the backup ref guarantees the previous tip is
  recoverable.

The engine never resolves a conflict, never runs `reset --hard`, `checkout --`,
`clean`, `stash` or `--force` itself.

### Decision 6: Brokered request

`openspec-sandbox` already advertises `--contract`; add feature
`rebase-broker`. The broker request grows a second closed shape:
`{action: "rebase", checkout: <abs path>, mode: "start"|"continue"|"abort",
session: <name or null>}`, exactly those keys. The existing
`{bead_id, checkout}` shape is unchanged. `checkout` is validated by the same
helper as task-done (registered worktree root of the same repository); the
engine then performs Decision 4 itself, so a direct and a brokered call refuse
identically. Response `{ok, status: "done"|"up-to-date"|"paused"|"refused",
output}`; the client prints `output` and maps `status` to the exit code of
Decision 3. A broker from an older launch rejects the new shape; the client turns
that into: "this session's sandbox broker predates rebase brokering; nothing was
changed; ask the operator to run `./scripts/nogg worktree rebase <record>
--allow-live-session` from an unfenced shell, or relaunch". The client socket
timeout for this action is raised (the engine fetches and replays commits) and
requests are served one at a time as today.

### Decision 7: Detecting a half-applied checkout

A pure, read-only classifier over one worktree path, shared by the engine's
refusal text, `doctor`, `recover` and `repair`:

- `operation-in-progress` — any state in Decision 4.3. Not half-applied; reported
  as such, with Nogg's own paused rebase named.
- `clean`.
- `half-applied` — no operation in progress, at least one dirty path, and **every**
  dirty path is reproducible from upstream: for a modified or untracked path the
  worktree bytes equal the blob at `origin/develop:<path>`; for a deleted path the
  path is absent at `origin/develop`. This is the #241 signature (upstream files
  written, `HEAD` unchanged, no state) and is provable without trusting a
  heuristic count.
- `mixed` — some dirty paths are reproducible, others are not (the Lead's own
  edits, or files that differ from both `HEAD` and upstream). Reproducible paths
  are listed as restorable; every other path is listed as "your work — untouched".
- `dirty` — no dirty path is reproducible from upstream: ordinary work in
  progress, never reported as a problem.

`recover` raises attention for `half-applied` and `mixed`; `doctor` prints a
`NOTE`. A leftover `.nogging/state/rebase/*.json` journal at `running` with no
operation in progress, or at `paused` with no `rebase-merge/`, is reported with
its backup ref. The hint is a path-scoped command built from the classification:
`git restore --source=HEAD --staged --worktree -- <reproducible tracked paths>`
and `git clean -f -- <reproducible untracked paths>`, never `reset --hard` and
never a directory-wide `clean -fd`. Rejected: a count threshold ("more than N
modified files") — it flags legitimate large edits and misses small partial
applies; byte equality with the upstream blob is the evidence.

### Decision 8: `worktree repair`

`nogg worktree repair <record> [--apply]` runs the classifier. Dry-run (default)
prints exactly what `--apply` would restore and what it leaves. `--apply` first
writes a snapshot commit of the **entire** dirty state (tracked changes and
untracked files, via a temporary index, so nothing in the working tree changes)
to `refs/nogg/repair-backup/<branch>/<UTC-stamp>`, then restores only the
reproducible paths with the path-scoped commands of Decision 7. It refuses
`operation-in-progress`, refuses when a live foreign session works there (same
rule as Decision 4.5) and does nothing for `dirty` or for the non-reproducible
paths of `mixed`. Because it only removes bytes that exist identically at
`origin/develop` and snapshots everything first, no recovery step can lose a
Lead's work. `repair` is not brokered: the paths a failed
fenced checkout wrote are outside `openspec/`, which a Lead can restore itself,
so a fenced caller gets the dry-run output and the printed hint, and `--apply`
from a fence refuses any `openspec/` path and names it for the operator.

Rejected: a flag that runs `git reset --hard`/`clean -fd` "after confirming"
(confirmation cannot prove the tree holds only upstream bytes; the classifier
can).

### Decision 9: Stop the damage at the source

- `scripts/hooks/pre-rebase` (git passes upstream and branch): when
  `NOGG_OPENSPEC_FENCED=1` or `openspec/` is not writable, and `git diff
  --name-only HEAD <upstream> -- openspec/` is non-empty, exit 1 before git
  touches the tree, naming the supported command. It catches `git rebase` and
  `git pull --rebase`. It cannot catch `git merge`/`git pull` (no `pre-merge`
  hook before the checkout), which the prompt rule and the classifier cover.
  Installed by `scripts/install-hooks` and shipped like `commit-msg`. As for the
  other Nogging hooks, a repository whose `core.hooksPath` diverts git away from
  `.git/hooks` does not run it (a documented limitation); there the prompt rule,
  the broker command and detection are the whole defence.
- The `no-autonomous-claim` and `autonomous` launch prompts gain one rule: do not
  run `git rebase`, `git merge` or `git pull` to integrate upstream while
  `openspec/` is read-only; run `./scripts/nogg worktree rebase`, and on a refusal
  or a pause follow its output; a dirty tree you did not make is reported with
  `./scripts/nogg doctor`, never reset.

Rejected: static permission denies on `git rebase`/`git pull`. Planners and
`--full-access` Leads legitimately run them, the profiles are shared, and a deny
cannot see the read-only mount.

### Decision 10: Residual risks and limitations

- A fenced agent can name another session in the request or ask to rebase another
  Lead's registered worktree; the clean-tree rule, the live-session guard and the
  backup ref make that an accident-class risk only. The broker is not an
  authentication boundary, as for `task-done`.
- Rebasing rewrites history: if the branch was already pushed, the next push
  needs `--force-with-lease`, which only a trusted session can do. The command
  prints that note when `origin/<branch>` exists; it never pushes.
- The real read-only mount cannot be exercised in CI (Decision 1). The docs task
  records a short host recipe the operator can run once per release.
- A session launched before this change keeps its old broker until relaunched;
  the hand-off message in Decision 6 covers it.
