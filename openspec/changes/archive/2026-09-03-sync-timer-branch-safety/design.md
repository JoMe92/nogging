# Design

## Context

`sync()` in `scripts/specforge`:

```python
def sync():
    path = lock("sync", CFG["sync_lock_ttl_seconds"])
    tasks, issues, problems = validate()
    ...                                    # write execution-log.md / flip checkboxes
    if changed:
        run("git", "add", ...)
        run("git", "commit", "-m", "chore(sync): mirror Beads execution evidence",
            "-m", "SpecForge-Writer: sync", env={... "SPECFORGE_WRITER": "sync"})
    data_dir(STATE).joinpath("last-success.json").write_text(json.dumps({"at": now()}) ...)
```

There is already a `fresh_lock(name, ttl)` helper (returns the lock info if the
lock exists and is younger than `ttl`, else `None`) — the planning-lock check
reuses it. `sync_now()` is the operator path (`sync --now` / the `/sync-now`
command); it calls `sync()` after signalling / choosing the direct run.

`W6` (the staleness-aware planning guard) already landed in
`tool-agnostic-write-boundary`; this change is only about the *sync writer*, not
the pre-edit guard.

## Goals / Non-goals

- Goal: a timer-driven `sync` never creates a commit while a branch operation,
  a planning session, or a protected-branch checkout is in play.
- Goal: a skipped tick is a no-op, not a failure — no `sync-failure.json`, no
  backoff, `last-success.json` unchanged, the next tick just tries again.
- Goal: an operator-invoked `sync --now` still works on `develop`/`main` (a
  deliberate catch-up), but still refuses a genuine mid-merge.
- Goal: the branch a sync commits on is visible after the fact.
- Non-goal: `specforge recover`, the resumption protocol, commit-before-
  materialize, the intent-breadcrumb rule — all deferred to
  `resilient-interrupted-runs`.
- Non-goal: making the timer branch-*aware* in the sense of choosing a branch;
  it only refuses unsafe ones.
- Non-goal: materializing Beads or editing implementation files in this planning
  session.

## Decisions

### `repo_sync_state()` — one function, three outcomes

A helper returns `("ok", branch)` / `("skip", reason)` given the repo state:

1. **Planning session active** — `fresh_lock("planning", CFG["planning_lock_ttl_seconds"])`
   is not `None` → `("skip", "planning session active")`.
2. **Mid-operation** — any of `.git/MERGE_HEAD`, `.git/rebase-merge`,
   `.git/rebase-apply`, `.git/CHERRY_PICK_HEAD`, `.git/BISECT_LOG` exists
   (resolve `.git` via `git rev-parse --git-dir` so worktrees work) →
   `("skip", "<op> in progress")`.
3. **Detached HEAD** — `git symbolic-ref -q --short HEAD` exits non-zero →
   `("skip", "detached HEAD")`.
4. **Protected branch** — the symbolic-ref branch is in
   `CFG["sync_protected_branches"]` (default `["main", "develop"]`) →
   `("skip", "on protected branch <b>")`.
5. Otherwise `("ok", branch)`.

### Where the check goes

`sync()` calls `repo_sync_state()` **before taking the sync lock**. On `skip`:
print `sync: skipped (<reason>)`, return normally (exit 0), touch nothing —
specifically not `last-success.json` and not `record_failure`. On `ok`: proceed
exactly as today, and pass the branch through so it can be recorded.

`sync_now()` passes a flag that makes `repo_sync_state()` treat outcome 4
(protected branch) as `ok` — the operator explicitly asked — but keeps 1–3 as
skips (a mid-merge or a held planning lock is still unsafe even on request; the
message tells the operator to finish that first).

### `last-success.json` gains `branch`

`{"at": <iso>, "branch": <name>}`. On a successful commit, `sync()` compares the
new branch with the stored one; if different, it prints
`sync: note — mirroring on <new> (last run was on <old>)`. Purely informational;
`doctor` can surface the stored value.

### Config

`.specforge/config.json` gains `"sync_protected_branches": ["main", "develop"]`.
An operator who does work directly on `develop` (against the operating model)
can set it to `["main"]`. `scfg`-style default so an un-upgraded config still
works.

## Risks / open questions

- If someone genuinely does day-to-day work on `develop`, the timer stops
  auto-mirroring for them until they move to a change branch or run `sync --now`.
  That is the intended nudge toward the one-branch-per-change model, and
  `sync --now` is the escape hatch; documented in `docs/failure-recovery.md`.
- `.git` discovery must use `git rev-parse --git-dir` (not a literal `.git/`)
  so the checks work when `sync` runs inside a linked worktree.
- A tick that skips repeatedly (e.g. a long-lived planning session) is silent
  except for its stdout line, which the timer discards. `doctor` should report
  "last sync skipped: <reason>" so a stalled mirror is visible — fold a
  `last-skip.json` (or a field on the failure/█success record) into the tasks.
- The protected-branch list is a policy choice; keep it a config key so it is
  not a code change to adjust.
