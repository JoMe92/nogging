## 1. Shared tmux server (branch prefix fix/, sequential)

- [x] TASK-HSS-001 [standard] Per design Decision 2: fenced callers pass tmux -N on every command; a fenced session launch whose tmux server is down is refused in the backend prepare step before any record, settings or log, pointing to an unsandboxed launch; unfenced argv unchanged. Check: new scripts/session-tmux-fenced-server.test.sh (tmux argv stub, refusal without side effects, race ends failed); scripts/test.

- [ ] TASK-HSS-002 [standard] Per design Decision 3: classify the dedicated tmux server via SO_PEERCRED and ns/pid+ns/mnt links as host, sandboxed, outside, down or unknown; doctor WARN, session list NOTE, orchestrator status line, WARN on orchestrator run and unfenced launch; never kill or signal the server. Check: new scripts/session-tmux-server-namespace.test.sh (Python listener, short TMUX_TMPDIR, injected namespaces); scripts/test.

## 2. Independent fixes (one prefix each, start at once)

- [x] TASK-HSS-003 [standard] Per design Decision 4 (N4): resolve the orchestrator lock, slug, session name, unit name and live-session lookup from the main checkout; orchestrator run in a linked worktree refuses before locking; a worktree-local lock is reported and ignored. Check: new scripts/orchestrator-canonical-lock.test.sh (temp repo plus linked worktree, stubbed bd/systemctl/loginctl, live child holder); scripts/test.

- [x] TASK-HSS-004 [routine] Per design Decision 5 (N1): task_done sends one checkout-aware broker request; on the pre-update refusal it fails non-zero with a relaunch instruction, sends no second request, ticks nothing and never falls back locally. Check: new scripts/task-done-mixed-broker.test.sh (Python broker stub on a short socket recording requests); scripts/test.

- [ ] TASK-HSS-005 [standard] Per design Decision 6 (N2): nudge --message clears pending input by bounded ctrl+u repeats, then a bounded backspace fallback, and types only on an empty composer; it submits only when the composer holds exactly the message, else fails with nothing submitted; Claude, Codex fallback, Antigravity; both backends. Check: new scripts/session-nudge-clear.test.sh (derived wrapped fixtures, tmux stub, fake herdr); scripts/test.

- [x] TASK-HSS-006 [routine] Per design Decision 7 (N3): docs/using-with-herdr.md quotes the real advisory `NOTE: <N> foreign herdr pane(s) left untouched`; no behaviour change. Check: new scripts/docs-herdr-foreign-note.test.sh asserting the guide quotes the format string in scripts/nogg; scripts/test.

## 3. Documentation and acceptance (branch prefix docs/, sequential)

- [ ] TASK-HSS-007 [standard] Per design Decision 8: document the fenced tmux refusal and the nudge clear and exact check (running-work-in-sessions), the sandbox-born tmux server, the worktree orchestrator lock and the task-done relaunch (failure-recovery), and the host-only tmux birth and canonical orchestrator lock (operating-model, architecture). Check: scripts/test green (docs, installation, security, package-manifest suites), links resolve.

- [ ] TASK-HSS-008 [complex] Per design Decision 9: short real Pi re-acceptance on a throwaway tmux socket: sandboxed tmux birth refused, then host start and survival; N4 lock and unit from a worktree; live D10 task-done tick; hardening step 43 on tmux and herdr plus steps 9, 12, 15; the N3 wording. Write docs/acceptance/<date>-session-stability.md unsigned with an empty Signed-off-by line. Check: report committed, scripts/test green.

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` = A depends on B): 002<-001, 002<-003, 007<-001, 007<-002, 007<-003, 007<-004, 007<-005, 007<-006, 008<-007. TASK-HSS-001, 003, 004, 005 and 006 have no dependency and can start at once on five distinct branch prefixes. Branches are `<type>/harden-session-supervision` with the lane prefix from design.md *Dependencies and parallel lanes*: fix/ 001-002; chore/ 003; refactor/ 004; feat/ 005; docs/ 006-008. A lane's next task reuses the prefix only after the previous branch is integrated and deleted. Each task's full contract is its design Decision plus the requirements of the capability spec it names.

## Execution contract

The Main Worker claims every task and implements it only in its own allocated worktree on its lane branch. Before allocating a dependent worktree, verify that every prerequisite execution commit is integrated into develop; Bead closure alone is not enough. Follow design Decision 1 for every test: no Dolt or bd, no PID-range assumptions, no unshare, socket paths under 108 bytes. Run each task's named checks, then commit with a Conventional subject ending in the real Bead token, push the lane branch and open the pull request against develop; only then run bd close and scripts/nogg task-done, and append the SHA and evidence to the Bead. Agents never hand-edit OpenSpec. Discoveries carry the discovery label and prose. Nobody signs human acceptance.
