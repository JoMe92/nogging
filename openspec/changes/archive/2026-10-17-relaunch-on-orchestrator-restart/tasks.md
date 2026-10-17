## 1. Helper extraction (branch prefix refactor/)

- [x] TASK-ORR-001 [routine] Per design Decision 2: factor out orchestrator session termination into terminate_orchestrator_session(exit_reason) in scripts/nogg covering tmux Ctrl+C, grace wait, kill fallback, record transition to stopped and lock release; use it in orchestrator_stop. Check: scripts/orchestrator.test.sh; scripts/test.

## 2. Restart sequence (branch prefix fix/)

- [x] TASK-ORR-002 [standard] Per design Decisions 1 and 3: update orchestrator_restart in scripts/nogg to stop unit, terminate session via helper with exit reason 'restarted by operator', and start unit; add CLI flag --supervisor-only to restart unit only without session kill. Check: python3 -m py_compile scripts/nogg; scripts/nogg orchestrator restart --help; scripts/test.

## 3. Regression tests and documentation (branch prefixes test/ and docs/)

- [x] TASK-ORR-003 [standard] Per design Decision 4: add regression tests in scripts/orchestrator.test.sh verifying orchestrator restart terminates live tmux session and calls stop/start, while --supervisor-only preserves live session and calls restart; stubbed systemctl and tmux, no Dolt or bd. Check: scripts/orchestrator.test.sh; scripts/test.

- [x] TASK-ORR-004 [routine] Per design Decision 5: document in docs/operating-model.md and docs/running-work-in-sessions.md that orchestrator restart terminates the live session and relaunches Claude with current prompt and settings while resuming transcript, and document --supervisor-only. Check: scripts/test.

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` = A depends on B): 002<-001, 003<-002, 004<-002. TASK-ORR-001 has no prerequisites and starts first. TASK-ORR-002 depends on TASK-ORR-001. Once TASK-ORR-002 is integrated, TASK-ORR-003 (test) and TASK-ORR-004 (docs) can proceed in parallel on their respective branch prefixes. Branches are `<type>/relaunch-on-orchestrator-restart` with the lane prefixes from `design.md`: refactor/ for 001; fix/ for 002; test/ for 003; docs/ for 004. Each task's full contract is its design Decision plus the requirements of the capability spec it names.

## Execution contract

The Main Worker claims every task and implements it only in its own allocated worktree on its lane branch. Before allocating a dependent worktree, verify that every prerequisite execution commit is integrated into develop; Bead closure alone is not enough. Follow design Decision 4 for every test: no Dolt or bd, no PID-range assumptions, no unshare, stubbed tmux and systemctl. Run each task's named checks, then commit with a Conventional subject ending in the real Bead token, push the lane branch and open the pull request against develop; only then run bd close and scripts/nogg task-done, and append the SHA and evidence to the Bead. Agents never hand-edit OpenSpec. Discoveries carry the discovery label and prose. Nobody signs human acceptance.
