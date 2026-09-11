## Context

See `proposal.md` for motivation and the accompanying delta specs for behavior.
Today `scripts/specforge` supervises sessions and protects the OpenSpec
boundary, but it does not allocate a Git worktree for planning or execution.
The `/plan` prompts describe planning in the caller's checkout, and the branch
checker accepts only one-segment planning topics. GitHub CLI is already used for
release and operational workflows, but PR creation and CI repair are not a
standard agent lifecycle.

## Goals / Non-Goals

**Goals:**

- Make a worktree and branch an explicit, durable unit of agent assignment.
- Supply the same lifecycle for Claude, Codex, and Pi without weakening their
  existing authority/profile boundaries.
- Make PR-to-`develop`, CI repair, and human merge handoff mechanically clear.
- Make cleanup safe, inspectable, and recoverable.

**Non-Goals:**

- Replacing GitHub branch protection, PR review rules, or GitHub Actions.
- Automatically merging an implementation PR or publishing a release.
- Deleting dirty worktrees, unmerged branches, or user-owned worktrees.
- Managing worktrees belonging to repositories other than the active
  SpecForge checkout.

## Decisions

### Add a durable `worktree` command group to `scripts/specforge`

`scripts/specforge worktree` will own worktree records under
`.specforge/state/worktrees/` and expose a small lifecycle:

- `create-plan --change <change> --plan-id <id> --description <slug>` fetches
  `origin/develop`, creates a unique branch
  `plan/<plan-id>/<description>` and a sibling planning worktree, records the
  source SHA, branch, path, change and owner, then prints the exact `cd` path.
- `create-implementation --bead <id> --branch <type>/<slug>` fetches current
  `origin/develop`, rejects `develop`/`main` or a non-conforming branch,
  creates a sibling worktree and records the assigned Bead and source SHA.
- `status` reconciles records with `git worktree list`, reporting stale,
  missing, dirty, and integrated worktrees without changing them.
- `cleanup <record>` verifies the worktree is clean and its branch is merged
  into `develop`; only then it removes the worktree and deletes its local
  branch. Otherwise it reports the recovery action required.

A record is created before the worktree command completes, allowing `recover`
and `doctor` to surface interrupted allocation or cleanup. Sibling paths are
derived from the repository slug plus kind, branch slug and collision-resistant
suffix; callers cannot point at another existing worktree.

Alternative considered: agents running raw `git worktree` commands from prompts.
It cannot provide durable ownership, collision detection, safe cleanup, or
consistent behavior across agents, so it is rejected.

### Keep planning integration explicit and sequenced

The generated planning worktree is the only place where `plan-begin` opens the
OpenSpec boundary and artifacts are written. `/plan` obtains/creates it before
opening that boundary, commits planning artifacts with the existing planning
writer trailer, validates, materializes after that commit, and fast-forwards or
merges the validated plan into `develop` only under the authority already
granted to a planning session. It then invokes safe cleanup.

The planning branch keeps the hierarchical name required by the change, while
the legacy `plan/<topic>` form remains valid so existing callers do not break.
The single branch-check implementation, pre-push hook, and CI invariants remain
the enforcement point.

Alternative considered: create a worktree after `plan-begin`. This leaves the
shared checkout writable during allocation failure, so allocation must precede
the lock and boundary opening.

### Bind execution worktrees to Beads and PR delivery

The execution prompt flow will require a claimed Bead before
`create-implementation`. It records the Bead and base SHA, directs the agent to
work only at the returned path, and rejects implementation from `develop`.
Existing conventional branch types remain the source of implementation branch
names; for change-scoped tasks, the existing branch checker still resolves the
change slug.

After local validation, agent instructions use `gh pr create --base develop`
with a standardized body containing task/plan links, decisions, validation, and
limitations. A PR helper will locate the branch's PR, record its URL in the
worktree record, and inspect required checks. It will not invoke any merge
operation. The five-minute initial CI delay is orchestrated by the agent
workflow (not a shell sleep): it stores `ci_not_before` in the record so an
interrupted session resumes the same wait rather than restarting it.

Alternative considered: a single blocking shell command that sleeps five
minutes. Durable timestamp state permits recovery and avoids tying up an agent
process.

### Treat CI repair as a state loop with a human terminal state

The PR helper reports queued, pending, failed, and successful required checks
using GitHub Actions/PR data. Agent prompts require failures to be inspected and
repaired on the recorded worktree branch, then to push and reset
`ci_not_before` for the next observation. When all required checks are green,
the record becomes `ready_for_review` and the agent stops. No command in this
flow merges the PR; cleanup of implementation worktrees is available only after
the user's integration has made the branch reachable from `develop`.

### Classify review changes in prompts, record small work in Beads

The common execution prompt will define the small/large test from the approved
workflow. Small review work creates a child/follow-up Bead before editing in
the existing recorded worktree, then repeats the local/PR/CI loop. Large work
is handed to `/plan`, which allocates a new planning worktree and branch;
agents do not broaden an active implementation branch on their own.

## Risks / Trade-offs

- [A worktree path is manually removed or its branch is deleted] → `status`,
  `recover`, and `doctor` reconcile the durable record and report an actionable
  stale state; they never recreate or delete it automatically.
- [Concurrent allocation chooses the same name] → record creation and Git
  worktree creation use unique suffixes and reject existing paths/branches.
- [The remote or GitHub CLI is unavailable] → allocation/PR status reports a
  retryable failure while preserving its record and worktree; it never falls
  back to the shared checkout.
- [A planning integration races with a changed develop] → integration fetches
  and checks ancestry, then stops for rebase/conflict resolution rather than
  force-pushing or overwriting `develop`.
- [Five-minute CI delay slows trivial PRs] → it is an explicit product rule;
  the stored deadline allows other work and recovery during the wait.

## Migration Plan

1. Add worktree record/state support, lifecycle commands, recovery/doctor
   reporting, and unit tests using throwaway repositories.
2. Extend branch validation and tests for hierarchical planning branches.
3. Update planning and execution prompts, launch guidance, and operating
   documentation to invoke the lifecycle.
4. Add PR/CI state helpers and tests with mocked GitHub CLI responses.
5. Exercise an end-to-end planning worktree and an implementation PR fixture;
   retain old one-segment planning branch support throughout rollout.

Rollback is a normal revert of this change. Existing manually created worktrees
remain untouched; records can be inspected and cleaned only by their explicit
safe-cleanup path.

