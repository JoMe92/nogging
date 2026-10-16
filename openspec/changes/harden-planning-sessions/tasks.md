## 1. Independent code fixes (one prefix each, start at once)

- [x] TASK-HPS-001 [standard] Per design Decision 3 (#176): worktree cleanup refuses before any removal when the worktree, a path under it or its Git directory is in /proc/self/mountinfo, when the caller's cwd is inside it, or when another active session record works there; an unreadable mount table refuses. Check: new scripts/worktree-cleanup-in-use.test.sh (injected mount table, tree/branch/record unchanged); scripts/test. Branch fix/.

- [ ] TASK-HPS-002 [standard] Per design Decision 4 (#176): session stop of the owning planner waits within its grace for the owner to exit, then releases the lock without --force; a kept lock and recover name 'session stop <name>'. Check: new scripts/planning-close-order.test.sh (plan-end from the planning worktree, live and reaped child owner, in-process tmux stubs); scripts/test. Branch refactor/.

- [x] TASK-HPS-003 [routine] Per design Decision 5 (#177): agy-guard accepts search_web with a non-empty string query (trusted allow, restricted force_ask); every denial names its cause and a sanitized tool name, never argument values; add the derived 1.4.0 search_web fixture with a README. Check: new scripts/agy-guard-web-search.test.sh; existing agy-guard.test.sh unchanged; scripts/test. Branch feat/.

- [ ] TASK-HPS-004 [standard] Per design Decision 6 (#178): refuse a Codex or Antigravity planning launch without --profile or --full-access before any side effect, naming both flags; explicit restricted prints a NOTE; every launch prints profile=/prompt=; Claude implicit planning warns; restricted Codex prints the Dolt note. Check: new scripts/planning-launch-profile.test.sh (tmux PATH stub never called); scripts/test. Branch chore/.

## 2. Documentation and acceptance (branch prefix docs/, then test/)

- [ ] TASK-HPS-005 [standard] Per design Decisions 2 and 7: state plan-end before worktree retirement, the hand-off line and 'openspec validate <change> --strict --no-interactive' on the planning prompt, the four /plan surfaces, the kickoff text, AGENTS.md and template, the flow docs, the orchestrator prompt and command, and failure-recovery. Check: updated scripts/planning-docs.test.sh and planning-kickoff.test.sh green; scripts/test. Branch docs/.

- [ ] TASK-HPS-006 [standard] Per design Decision 8: document that restricted Codex cannot reach the shared Dolt server, the host-owned Dolt rule in the launch prompts, search_web and named denials for Antigravity, the planning launch rule and profile= line, and orchestrator planner launches with --profile trusted. Check: new scripts/runtime-guidance-docs.test.sh; scripts/test. Branch docs/ (after TASK-HPS-005).

- [ ] TASK-HPS-007 [complex] Per design Decision 9: short live re-acceptance in a scratch consumer repo: Codex launch refusal; trusted Codex planner plan-end from its worktree, own cleanup refused with no deletion, operator stop plus cleanup without --force; Claude self-retirement; agy search_web trusted and restricted with the query key confirmed. Write docs/acceptance/<date>-planning-robustness.md unsigned. Branch test/.

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` = A depends on B): 005<-001, 005<-002, 006<-003, 006<-004, 006<-005, 007<-006. TASK-HPS-001, 002, 003 and 004 have no dependency and can start at once on four distinct branch prefixes. Branches are `<type>/harden-planning-sessions` with the lane prefix from design.md *Dependencies and parallel lanes*: fix/ 001; refactor/ 002; feat/ 003; chore/ 004; docs/ 005-006; test/ 007. A lane's next task reuses the prefix only after the previous branch is integrated and deleted. Each task's full contract is its design Decision plus the requirements of the capability spec it names.

## Execution contract

The Main Worker claims every task and implements it only in its own allocated worktree on its lane branch. Before allocating a dependent worktree, verify that every prerequisite execution commit is integrated into develop; Bead closure alone is not enough. Follow design Decision 1 for every test: no Dolt or bd, no PID-range assumptions, no unshare or real mounts, no running tmux server. Run each task's named checks, then commit with a Conventional subject ending in the real Bead token, push the lane branch and open the pull request against develop; only then run bd close and scripts/nogg task-done, and append the SHA and evidence to the Bead. A Codex Lead needs --full-access or --profile trusted to reach the shared Dolt server. Agents never hand-edit OpenSpec. Discoveries carry the discovery label and prose. Nobody signs human acceptance.
