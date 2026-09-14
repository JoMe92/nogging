## Why

Agent work currently shares a checkout unless an operator creates isolation
manually. That makes concurrent planning and implementation vulnerable to
branch switches, working-tree collisions, and accidental integration work on
`develop`.

## What Changes

- Add a managed Git-worktree lifecycle for planning and implementation agents.
- Require each planning run to use an isolated planning branch and worktree
  based on current `develop`, then integrate its validated planning commit into
  `develop` and clean up the planning worktree when appropriate.
- Require execution work to use an implementation worktree and conventional
  branch from `develop`, with delivery through a pull request targeting
  `develop` rather than a direct integration commit.
- Add autonomous post-PR CI inspection and repair: agents wait before the
  first inspection, fix failures in the same worktree, and stop for human
  review only when required checks are green.
- Make recovery and task-mapping diagnostics resolve planned work from the
  active integration ref so a shared `main` checkout does not falsely report
  valid `develop`-only Beads as orphaned.
- Define how agents classify requested PR follow-ups: small changes become and
  close a Bead on the existing branch; large changes begin a new planning
  cycle.
- **BREAKING** Extend allowed planning branch names from `plan/<slug>` to
  hierarchical `plan/<planning-id>/<description>` while retaining the current
  one-segment form for compatibility.

## Capabilities

### New Capabilities

- `agent-worktrees`: isolated worktree creation, ownership, cleanup, PR
  delivery, CI repair, and review handoff for planning and execution agents.

### Modified Capabilities

- `branch-discipline`: permit and validate hierarchical planning branch names
  that identify a planning run and its subject.
- `workflow-commands`: make `/plan` establish and use an isolated planning
  worktree rather than authoring OpenSpec in a shared checkout.

## Impact

- Affected systems: `scripts/specforge`, session launch prompts/profiles,
  branch-name validation and hooks, recovery/doctor diagnostics,
  Codex/Claude/Pi planning instructions,
  GitHub PR/Actions integration, and repository operating documentation.
- No new runtime dependency is required beyond Git and the existing GitHub CLI
  integration used by supervised agent workflows.
