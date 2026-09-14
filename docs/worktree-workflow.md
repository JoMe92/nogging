# Worktree-based agent workflow

Every planning and implementation run owns one Git worktree and one branch.
The shared checkout is an integration surface, not an agent workspace.

## Planning

From a clean shared checkout, allocate a planning worktree from the latest
remote `develop`:

```bash
scripts/specforge worktree plan <planning-id> <description>
```

Change into the printed path, run `plan-begin`, author and validate OpenSpec,
commit as the planning writer, materialize the Beads, and run `plan-end`.
Fast-forward the planning branch into `develop` and push `develop` before
starting implementation. Cleanup accepts only a clean, integrated worktree:

```bash
scripts/specforge worktree cleanup <planning-record.json>
```

## Implementation

Claim the assigned Bead first, then allocate its implementation worktree:

```bash
scripts/specforge worktree implement <bead-id> <type/change-slug>
```

Perform edits, validation, and Bead-tagged commits only in that worktree. Push
the branch and create or locate its pull request against `develop`:

```bash
scripts/specforge pr open --plan <change> --task <task-id> \
  --decision '<decision>' --validation '<check>' --limitation '<limitation>'
```

The PR record stores the earliest initial CI inspection time. After that time,
inspect required checks with `scripts/specforge pr ci`. Failed checks remain on
the same branch for diagnosis and repair; `ready_for_user_review` means stop
and ask the user to review. It never means self-merge.

After user-directed integration, `worktree cleanup <record.json>` removes only
the exact clean worktree whose branch is contained in `develop`.

## Review changes

The agent classifies requested changes. Small, in-scope changes receive a Bead
and are resolved on the existing PR branch before CI is restored. Large or
uncertain architectural, interface, subsystem, or scope changes start a fresh
planning worktree and a new implementation cycle.
