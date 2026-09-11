# Tasks

## 1. Worktree state and branch discipline

- [ ] TASK-WT-001 Add durable worktree allocation records, status/recovery/doctor reporting, and throwaway-repository tests that prove records survive interrupted create or cleanup operations without deleting user work.
- [ ] TASK-WT-002 Extend `scripts/check-branch-name`, installed hooks, CI invariant coverage, and tests to accept `plan/<planning-id>/<description>` with kebab-case segments while preserving existing valid branch forms and rejecting malformed hierarchy.

## 2. Planning worktree lifecycle

- [ ] TASK-WT-003 Implement the planning-worktree creation command from updated `origin/develop`, including unique hierarchical plan branch/path generation, pre-allocation collision checks, durable record creation, and tests proving no shared checkout is modified.
- [ ] TASK-WT-004 Update Claude, Codex, and Pi `/plan` instructions plus operating documentation so planning allocates the dedicated worktree before `plan-begin`, commits and validates artifacts there, materializes after the planning commit, integrates the plan into `develop`, and performs only safe cleanup; verify the documented lifecycle in a fixture.

## 3. Implementation worktree lifecycle

- [ ] TASK-WT-005 Implement assigned-Bead implementation-worktree creation from updated `origin/develop`, conventional-branch validation, exclusive-worktree guards, and clean/integrated-only cleanup; verify concurrent fixture worktrees cannot overwrite, switch, or clean each other.
- [ ] TASK-WT-006 Update Lead/session prompts and operating documentation to require claimed-Bead implementation work exclusively in the allocated worktree, prohibit direct implementation commits on `develop`, and require relevant local validation and focused commits; verify each supported agent receives the guidance.

## 4. Pull request and CI repair lifecycle

- [ ] TASK-WT-007 Add a PR helper/state flow that creates or locates a pull request targeting `develop`, records the PR URL and task/plan/decision/validation/limitation template, and never invokes a merge command; verify behavior using mocked GitHub CLI responses.
- [ ] TASK-WT-008 Add durable five-minute initial CI-inspection timing and required-check status handling; verify failed checks preserve the worktree for diagnosis/fix/push/recheck, while all-green checks mark the work ready for user review without merging.

## 5. Review follow-up policy and end-to-end validation

- [ ] TASK-WT-009 Document and encode the autonomous small-versus-large review-change policy: small changes create and resolve a Bead on the existing PR branch and restore CI, while large or uncertain changes start a new planning worktree; verify both routed flows in prompt/command tests.
- [ ] TASK-WT-010 Add end-to-end fixture coverage and user documentation for planning worktree → validated plan integration → implementation worktree → PR/CI handoff → safe cleanup, then run `scripts/test` and `./scripts/specforge validate` to verify the complete workflow.
