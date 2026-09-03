# Stop the sync timer from committing into a branch operation

## Why

`scripts/specforge sync` does `git add` + `git commit` unconditionally whenever a
closed Bead needs mirroring, on **whatever branch HEAD points at**, with no check
of the repository's state. The `specforge-sync.timer` fires it every 30 s. This
is weakness **W5** in `docs/source/crash-resilience-handoff.md`, and it has now
bitten three times, each time during an integration step (push feature branch →
`git switch develop` → `git merge --ff-only`):

- A `chore(sync)` commit lands on the feature branch *and* a second, duplicate
  mirror lands on local `develop` in the few-second window between the switch
  and the merge.
- Local `develop` and the feature branch then diverge (local `develop` carries
  the stray commit the feature branch does not), so `git merge --ff-only`
  aborts.
- Recovery each time was a manual `git branch -f` to the feature tip — safe, but
  it should not be needed.

The timer also has no problem interleaving with a planning session or running
while a merge/rebase is half-applied.

## What Changes

- **`sync` skips a tick when the repository is mid-operation or on a protected
  branch.** It does no mirroring and no commit, prints why, does **not** record
  a failure, and leaves `last-success.json` untouched so the next tick retries,
  when:
  - a fresh `planning.lock` is held (planning and sync must not interleave);
  - a merge, rebase, cherry-pick, or bisect is in progress
    (`.git/MERGE_HEAD`, `.git/rebase-merge/`, `.git/rebase-apply/`,
    `.git/CHERRY_PICK_HEAD`, `.git/BISECT_LOG`);
  - `HEAD` is detached;
  - `HEAD` is a protected branch (`main`, `develop` — from a new
    `sync_protected_branches` config key).
- **`sync --now` (operator-invoked) still runs on a protected branch** — the
  operator asked for it explicitly — but still skips a genuine mid-operation.
- **`last-success.json` records the branch** the last successful sync committed
  on; `sync` prints a one-line warning when the branch has changed since the
  last run.

## Capabilities

### New Capabilities

- `sync-safety`: the mechanical sync refuses to commit into a branch operation,
  a planning session, or a protected branch, and records the branch it last
  mirrored on.

### Modified Capabilities

<!-- none -->

## Impact

- Modified code: `scripts/specforge` (`sync`, `sync_now`, a `repo_sync_state()`
  helper, the `last-success.json` shape, the new config key), `.specforge/config.json`
  (`sync_protected_branches`), `scripts/specforge.test.sh`,
  `docs/architecture.md` / `docs/failure-recovery.md`.
- Behavioural change: the timer no longer auto-mirrors while you sit on
  `develop`/`main` directly — work happens on a change branch per the operating
  model, and `sync --now` covers a deliberate exception.
- Resolves crash-resilience discovery W5. The rest of the handoff
  (`specforge recover`, the resumption protocol, commit-before-materialize)
  stays for a separate `resilient-interrupted-runs` change.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
