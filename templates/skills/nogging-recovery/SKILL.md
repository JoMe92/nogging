---
name: nogging-recovery
description: What to do at session start and after an interrupted run - recover before bd ready, LIMBO and resumable Beads, stale locks, Beads owned by another session. Read it when a session starts, when recover reports something, or when a run was interrupted.
---

# Recovery: resuming a run

A planning or development run can stop mid-way: the token budget runs out, the
process crashes, the SSH session drops, or the operator switches tools. On
session start — fresh, resumed, or after a tool switch — **before selecting
work with `bd ready`**:

1. Let the session-start hook prime Beads context, or run `bd prime`.
2. Run `./scripts/nogg recover`.
3. Resolve every item it reports with the playbook in
   `docs/nogging/failure-recovery.md`, section "Resuming an interrupted run".
4. Only then select work with `bd ready`.

A session launched with `--bead` works only that Bead, starting from its
kickoff. It skips step 4, and whatever `recover` reports about any other Bead
it reports to the operator instead of resolving. Only
`session kickoff --change` widens that scope to the change.

## What `recover` reports

- **`LIMBO` or `resumable` Bead.** It has committed work, complete or only its
  first steps. Compare its commits (`git log --oneline --grep '\[<id>\]'`)
  with the task slice and finish what is missing. Once complete, run
  `./scripts/nogg test bead`, add the evidence note with every commit SHA and
  `bd close <id>`. **Never re-implement committed work**: that produces
  duplicate commits.
- **A Bead or worktree `owned by session <name>`.** It is not yours to adopt,
  even when it looks unfinished. Leave its worktree, branch, commits and notes
  alone and report it.
- **A Bead whose session `may still be running`.** Confirm the session ended
  with `./scripts/nogg session reap` before adopting it.
- **`in_progress`, `stale`, with a diff.** Finish the uncommitted diff, or
  `git stash` it and re-claim clean; record the decision in the Bead note.
  With no diff it likely never started: re-claim and work it normally.
- **Stale `planning.lock`.** Confirm no planning session is running, then
  `./scripts/nogg plan-end --force`. A lock that names a live supervised
  session is refused. Stop, cleanup and recovery never release another
  session's planning lock.
- **Orphan Bead** (an active Bead that lost its task mapping). An execution
  agent stops and reports it. A planning session restores the task line or
  cancels the Bead with a recorded reason; it never deletes it.
- **Crashed session record.** `./scripts/nogg session reap`, then
  `./scripts/nogg session cleanup`.
- **Working tree mid-merge or mid-rebase.** Finish or abort it before resuming.

## The breadcrumb

The agent's working memory does not survive an interruption. The one-line
`progress: <next step>` note on the Bead
(`bd update <id> --append-notes "progress: …"`) is the primary "where was I"
signal on resume, in any tool: read it first, and leave one before an
expensive or hard-to-reverse step and before ending a turn with a Bead still
`in_progress`.

## Multi-machine

When two machines wrote Beads before either pulled, follow
`docs/nogging/failure-recovery.md`; the `nogging-sessions` skill has the
multi-machine rules.
