---
name: nogging-lead-workflow
description: The Main Worker's path through one Bead - claim, worktree, staged tests, commits, close order and the evidence note. Read it when you claim, implement, test, commit or close a Bead.
---

# Lead workflow: one Bead from claim to evidence

The hard rules in the Nogging block of `AGENTS.md` always apply. This skill is
the order of work around them.

## 1. Before the claim

- Run `./scripts/nogg recover` and resolve what it reports before `bd ready`
  (the `nogging-recovery` skill has the playbook).
- In a supervised session, being launched is not permission to start a Bead:
  claim only the Bead the operator names, when they direct it. A session
  launched with `--bead` works only that Bead.
- Work only on a Bead that has been claimed by the Main Worker:
  `bd update <id> --claim`.

## 2. The task slice

`bd show <id>` gives the `openspec:task:<TASK-ID>` label. Read that one task
entry in `openspec/changes/<change>/tasks.md`, the design decisions it names
and the matching requirements, not the whole change. `openspec/` is read-only
for you: a wrong or missing spec is a discovery, never an edit.

A fast-lane Bead (label `ceremony:fast`) has no task entry. Its slice is the
title and the acceptance criteria on the Bead. Write a failing test first for
a bug, and stay inside the file and line limits `./scripts/nogg ceremony`
prints. When a commit, a test stage or `task-done` refuses with `needs-spec`,
stop implementing: add the labels `needs-spec` and `discovery` with a prose
note saying what grew and the counts, set the Bead `blocked`, and signal
`blocked "needs-spec"`.

## 3. The worktree

Implement only in the worktree allocated for the Bead:
`./scripts/nogg worktree implement <bead-id> <type/change-slug>`. Integrate
upstream only with `./scripts/nogg worktree rebase`. After user-directed
integration, `./scripts/nogg worktree cleanup <record.json>` retires it.
`docs/nogging/worktree-workflow.md` has the detail.

## 4. Commits and test stages

- Commit a Bead in several coherent steps, not as one commit at the end. Each
  commit stays within the configured commit range (`task_sizing.commit_lines`
  in `.nogging/config.json`; `./scripts/nogg task-sizing` prints it), is a
  Conventional Commit containing the Bead ID (e.g. `[SPEC-abc]`), and holds
  the tests for the code it changes.
- Test in stages, following the test policy
  (`docs/nogging/testing-policy.md`): `./scripts/nogg test changed` while
  working, `./scripts/nogg test commit` before each commit, and
  `./scripts/nogg test bead` once per Bead, before closing it. The full suite
  is CI's job: `./scripts/nogg test full` is only for a release, the nightly
  run or an explicit recorded reason. Never run `scripts/test` once per Bead.
- Weakening a test — deleting it, adding a skip, dropping assertions — takes a
  `Test-Integrity: <reason>` commit trailer and a discovery note on the Bead.
- Run a long command (a suite, a build) as one blocking call with a timeout
  long enough for it to finish. `./scripts/nogg run-quiet -- <command>`
  prints one line on success and only the tail on failure. Never poll a
  running command; the `nogging-sessions` skill has the per-runtime detail.
- Before an expensive or hard-to-reverse step, and before ending a turn with
  the Bead still `in_progress`, leave the breadcrumb:
  `bd update <id> --append-notes "progress: <what is done, what is next>"`.

## 5. Discoveries

Record every material discovery on the active Bead with the native Beads
`discovery` label plus a required human-readable note. Never encode it as
serialized data (no JSON, no key/value block), and never edit `openspec/`.

- Non-blocking, the task still finishes as specified:
  `bd update <id> --add-label discovery --append-notes "<what was found, the evidence, the suggested follow-up>"`
- Blocking, the task cannot be finished sensibly as specified:
  `bd update <id> --status blocked --add-label discovery --append-notes "<what was found, the evidence, why it blocks>"`,
  then switch to the next independent ready Bead.

The next planning session lists them with `bd list --label discovery`.

## 6. The close order

1. `./scripts/nogg test bead` passes.
2. `bd close <id>`.
3. Immediately `./scripts/nogg task-done <id>` to tick the Bead's mapped
   `tasks.md` line. It refuses unless the Bead is already closed. It writes
   `tasks.md` directly and needs no override of the write boundary. Bundle
   that tick into the Bead's last commit.
4. The evidence note, listing every commit SHA:
   `bd update <id> --append-notes "commits <sha>, <sha>; <evidence>"`.
5. When a specialist's delegated work is in a commit, that commit carries the
   `Co-authored-by` trailer (the `nogging-specialists` skill).

## 7. The end of the run

End every supervised run with a signal: a pushed pull request and
`./scripts/nogg session signal done "PR #<n> open"`, or
`./scripts/nogg session signal blocked "<why>"`. A Bead note alone is not a
signal. A refused step means signal blocked at once: never route around a
refusal by switching runtime or retrying.
