## 1. Safety lane (herdr-independent, starts immediately)

- [x] TASK-HHB-001 [routine] Per design Decision 2 (D6): session cleanup stops the shared tmux server only when its own listing succeeds and is empty, never because this checkout's records are retired; print the stop message only on a real stop. Check: new scripts/session-cleanup-shared-tmux.test.sh (foreign orchestrator session kept, empty server, failed listing) under Decision 1 rules; full scripts/test green.

- [x] TASK-HHB-002 [standard] Per design Decision 3: orchestrator lock records pid_start and pid_ns; one classifier for run, status, recover and doctor; a verified live holder (or legacy lock held by a live `nogg orchestrator run`) is never stale at any age; fenced or foreign-namespace callers never report it stale; TTL only for another host. Check: new scripts/orchestrator-lock.test.sh, live/reaped child PIDs, stubbed bd; scripts/test.

- [x] TASK-HHB-003 [standard] Per design Decision 4 (D10): task-done broker requests carry the caller's checkout root; the broker ticks only a worktree registered in the same repository at request time, refuses anything else without falling back, adds contract feature checkout-task-broker required by preflight. Check: new scripts/task-done-broker.test.sh via a callable handler (no unshare), linked worktree, stubbed bd; scripts/test.

## 2. herdr lane (branch prefix feat/, sequential)

- [x] TASK-HHB-004 [complex] Per design Decision 5 (D9): never start the herdr server when fenced (refuse before side effects, name session herdr-server start); receipt adds pid_ns and socket identity; records store terminal_id and the server namespace; liveness via terminal_id and shell_pid from any namespace; no /proc read or signal for a foreign-namespace PID. Check: new scripts/session-herdr-namespace.test.sh on the fake herdr; scripts/test.

- [x] TASK-HHB-005 [standard] Per design Decision 6 (D2): two agreeing herdr answers that the dedicated server is not running make its records vanished (list failed, reap, same-Bead launch and --resume proceed); doubt stays unknown; add idempotent scripts/nogg session herdr-server start (host only, ownership checks, legacy receipt upgrade, no record or pane). Check: new scripts/session-herdr-server-down.test.sh; scripts/test.

- [x] TASK-HHB-006 [routine] Per design Decision 7 (D1): herdr orphans are only panes whose label names a record of the current checkout (any state) with no live owner; panes naming no local record are foreign, never closed or adopted, and counted in one session list NOTE. Check: new scripts/session-herdr-ownership.test.sh with two checkouts' record stores on one fake herdr state; scripts/test.

- [x] TASK-HHB-007 [routine] Per design Decision 8 (D8): store the root pane from Nogging's own workspace create in workspace.json and close it after the next successful layout.apply (re-check unlabelled, same ID and terminal_id); recreate the workspace and retry once only on an explicit workspace_not_found error reply; doctor notes legacy root panes. Check: new scripts/session-herdr-root-pane.test.sh; scripts/test.

## 3. Both backends

- [x] TASK-HHB-008 [standard] Per design Decision 9 (D3): rewrite scripts/session-log-writer in stdlib Python, same path and positional CLI, chunked byte appends without waiting for LF, every generation and buffer within max-bytes, byte-exact, contract feature byte-stream required by the helper check; _archive_log archives all rotated generations. Check: new scripts/session-log-writer.test.sh (no-LF live growth, 3 MiB bound, cleanup); scripts/test.

- [x] TASK-HHB-009 [standard] Per design Decision 10 (D4, D5): Codex nudge --message delivers via codex queue like send; pane fallback verifies with a Codex composer classifier and fails as unverified, never `nudged`; Antigravity classifier ignores the status bar, herdr working/done counts as submitted, no extra Enter after delivery. Check: new scripts/session-nudge-agents.test.sh with spike-derived fixtures; existing nudge suites unchanged; scripts/test.

- [x] TASK-HHB-010 [standard] Per design Decision 11 (D7): support Codex exact resume; validate the UUID before side effects, record codex_thread_id, run codex resume <id> inside the wrapper with the cold-launch authority flags and no re-sent prompt, refuse when the installed Codex lacks a flag, add session-launch contract feature codex-resume. Check: new scripts/codex-exact-resume.test.sh with argv-capturing codex stub and committed resume help fixture; scripts/test.

## 4. Documentation and acceptance

- [x] TASK-HHB-011 [standard] Per design Decision 12: update using-with-herdr (host-namespace start, herdr-server start, server-down recovery, checkout-scoped orphans, root pane, terminal identity, live logs), failure-recovery (server down, orchestrator lock states), running-work-in-sessions, using-with-codex (exact resume), operating-model and architecture. Check: scripts/test green (docs, installation, security, package-manifest suites), links resolve.

- [ ] TASK-HHB-012 [complex] Per design Decision 13: real Pi re-acceptance on herdr 0.9.x with Claude, Codex and Antigravity plus a parallel tmux Lead; repeat failed checks 12, 13, 15, 18, 22, 32, 34, 35, regress the passed ones, add D6, lock, D10, D8 and both D9 topologies; write docs/acceptance/<date>-herdr-hardening.md unsigned with an empty Signed-off-by line. Check: report committed unsigned, scripts/test green, doctor shows herdr.

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` = A depends on B): 005<-004, 006<-005, 006<-001, 007<-006, 010<-009, 011<-001, 011<-002, 011<-003, 011<-004, 011<-005, 011<-006, 011<-007, 011<-008, 011<-009, 011<-010, 012<-011. TASK-HHB-001, 002, 003, 004, 008 and 009 have no dependency and can start at once on six distinct branch prefixes. The safety lane (001, 002, 003) never waits for herdr work. Branches are `<type>/harden-herdr-session-backend` with the lane prefix from design.md *Dependencies and parallel lanes*: fix/ 001; chore/ 002; refactor/ 003; feat/ 004-007; perf/ 008; test/ 009-010; docs/ 011-012. A lane's next task reuses the prefix only after the previous branch is integrated and deleted. Each task's full contract is its design Decision plus the requirements of the capability spec it names.

## Execution contract

The Main Worker claims every task and implements it only in its own allocated worktree on its lane branch. Before allocating a dependent worktree, verify that every prerequisite execution commit is integrated into develop; Bead closure alone is not enough. Follow design Decision 1 for every test: no Dolt or bd, no PID-range assumptions, no user namespaces, socket paths under 108 bytes. Run each task's named checks before closing it, then run bd close, immediately run scripts/nogg task-done, commit the execution change and the mapped tick together with the real Bead ID, and append the SHA and evidence. Agents never hand-edit OpenSpec. Discoveries carry the discovery label and prose. Nobody signs human acceptance.
