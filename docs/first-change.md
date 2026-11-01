# Your first change

This page walks you from a repository where Nogging is installed to your first
closed Bead. It is for someone who has finished the
[installation guide](installation.md) and now wants to see the loop run once:
plan a change, let a Lead Agent implement one task, review the pull request and
mirror the evidence back. Each step says what you should see. It does not
repeat the installation; if `./scripts/nogg doctor` is not clean yet, start
there.

Before you begin, the target repository needs two things the installer does not
create for you: a branch named `develop` and a remote named `origin`. Worktrees
are allocated from a freshly fetched `origin/develop`, and pull requests target
`develop`. A fresh repository with neither will fail at step 3 with a message
that `origin/develop` does not resolve.

## 1. Check that the machine is ready

```bash
./scripts/nogg doctor
```

You should see no `FAIL` lines. `WARN` and `NOTE` lines are advisory: they name
optional tools you have not installed, such as `tmux`, or state you may want to
review. If a line says a tool is missing, fix it and run `doctor` again before
going on. [Failure recovery](failure-recovery.md) explains the lines that point
at interrupted work.

## 2. Plan a change

In Claude Code, run:

```text
/plan
```

The Planning Agent asks what you want built, then works through a fixed
sequence: it allocates its own planning worktree, takes the planning lock,
writes an OpenSpec change with stable task IDs in `tasks.md`, each task a
vertical slice tagged with its size estimate `[~N loc]` and a `Tests:` field
that names its test scenarios and sizes, validates it,
commits it, materializes the tasks into Beads and wires their dependencies.
You should see it finish by releasing the lock and retiring the planning
worktree. Nothing it wrote touches your working branch.

If you are not in Claude Code, start the supervised planner instead and send it
its first instruction:

```bash
./scripts/nogg session launch --role planning --planning-id <planning-id> --description <description>
```

The roles and the planning lock are explained in the
[operating model](operating-model.md) and the
[session guide](running-work-in-sessions.md).

## 3. Find the work the plan created

```bash
bd ready
```

You should see one line per unblocked Bead, each with an ID such as
`PROJ-ab12` and the task title. Beads whose dependencies are still open do not
appear yet. Pick one and read it with `bd show <id>`: the labels tie it back to
its change and task, and the notes say which tier the planner chose for it.

## 4. Launch a Lead Agent on one Bead

```bash
./scripts/nogg session launch --role lead --bead <id>
```

You should see `launched <name>` followed by the Bead, the working directory,
the log path and an `attach:` hint. The session starts with restricted
authority. Read the [security and threat model](security-model.md) before you
add `--full-access`, and see
[Model selection](model-selection.md) for choosing the agent and effort.

The Lead claims the Bead, allocates its own worktree from `origin/develop` (see
the [worktree workflow](worktree-workflow.md)), implements the task there in
several commits. It tests in stages, following the [testing policy](testing-policy.md):
`./scripts/nogg test changed` while it works, `./scripts/nogg test commit` before each
commit and `./scripts/nogg test bead` once before it hands off. It does not run the
full suite; that is CI's job (see [Test control](test-control.md)).

## 5. Watch it work

```bash
./scripts/nogg session list
./scripts/nogg session log <name> --follow
```

`session list` shows each session with its state; yours should read as running.
`session log` tails what the agent is doing without attaching to it, and you can
stop following at any time. If a session stops making progress, `session watch`
flags stalls, and `session send <name> "<message>"` steers it. All of these are
described in [Running work in sessions](running-work-in-sessions.md).

## 6. Review the pull request

When the Lead finishes, it has committed the task in coherent steps, each
with the Bead ID in the subject, pushed its branch, opened a pull request
against `develop` and left an evidence note on the Bead. You should find the PR on GitHub with the Bead token
in its commits. Review it as you would any other pull request. The Lead never
merges its own pull request unless you started it with `--full-access` and told
it to; see the [worktree workflow](worktree-workflow.md).

Check the Bead too:

```bash
bd show <id>
```

You should see the status `closed` and a note listing every commit SHA and
the evidence the Lead gathered.

## 7. Mirror the evidence back

```bash
./scripts/nogg sync --now
```

Sync reads closed Beads and Git history and writes the evidence into the
matching OpenSpec change. You should see it report the changes it mirrored, or
a skip reason if there was nothing to do. If you enabled the sync timer at
install time, it does this on a schedule and you can skip the manual run. When
every Bead of a change is closed, `./scripts/nogg doctor` adds a note that the
change is ready to archive.

## 8. Triage discoveries

Leads record anything the plan did not anticipate as a discovery on the Bead.
In Claude Code, run:

```text
/discovery-review
```

You should see either `no pending discoveries` or a list, with blocking ones
first. For each one you choose to carry it into the next `/plan` session or to
acknowledge it. The command does not change the plan by itself.

## Where to go next

- [Running work in sessions](running-work-in-sessions.md) covers launching,
  steering and stopping sessions in depth.
- [Failure recovery](failure-recovery.md) covers what to do when a step above
  does not behave as described.
- [Using Nogging with Codex](using-with-codex.md) and
  [Pi](using-with-pi.md) cover running the same loop from another agent.
- The [FAQ](faq.md) answers common questions about the workflow.
