## 1. Gate

- [x] TASK-HDR-001 [complex] Gate spike per design Decision 1: install herdr v0.9.x user-level (~/.local/bin, no sudo/curl/wget, checksum verified); on the Pi under the real wrapper, recorder and HERDR_AGENT test (a) status, (b) ANSI in pane.read, (c) pane-ID stability, (d) native resume plus auto-restore disable, (e) recorder log without TUI break; record implementation facts, commit sanitized fixtures; two or more FAIL = blocking discovery. Check: Bead evidence note, scripts/test.

## 2. Seam

- [x] TASK-HDR-002 [complex] Add scripts/lib/session_backend.py (primitives, registry, normalized keys, capabilities, live() alive/unknown) and move tmux into scripts/lib/session_backend_tmux.py; route every scripts/nogg tmux call site through the seam; nogg_usage.py reservations use a {backend, argv} probe and still read legacy entries; ship both modules. No behaviour change. Check: full scripts/test unchanged and green, plus new scripts/session-backend.test.sh with a no-direct-tmux grep guard.

- [x] TASK-HDR-003 [standard] Backend selection and per-record dispatch (design Decision 4): session_backend key (absent means tmux, template documented), launch --backend precedence, refusal before side effects, record backend and backend_ref (legacy is tmux), lifecycle ops resolved from the record, session list BACKEND column, unknown liveness never reaped, orchestrator pinned to tmux. Check: new scripts/session-backend-select.test.sh plus full scripts/test green.

## 3. Parallel foundations

- [x] TASK-HDR-004 [complex] Implement the PTY recorder per design Decision 5, including terminal I/O, resize, logging, signal and exit handling, and side-effect-free contract mode. Packaging is done by TASK-HDR-006. Check: recorder tests cover TUI I/O, rotation, writer failure and pane-close flush; scripts/test.

- [x] TASK-HDR-005 [standard] Add a stateful fake herdr CLI at scripts/fixtures/herdr/bin/herdr ($HERDR_STUB_DIR, like the tmux stub) reproducing the spike-verified CLI forms and JSON for pane create/list/get/process_info/send/read (attribute and plain variants)/close, agent status, version and reachability, a simulated server restart, injectable failures and a call log. Check: new scripts/herdr-stub.test.sh comparing shapes with the spike fixtures plus full scripts/test green.

## 4. herdr backend

- [ ] TASK-HDR-014 [standard] Correct the fake herdr per design Decision 14: synthetic CLI forms herdr 0.9.5 lacks (layout apply, pane create, pane split --command, ping, server start/run/restart) fail with usage, exit 2; add a fake 0600 Unix-socket server at the session list socket_path serving layout.apply on shared state, opt-in real pane process, socket faults, test controls off the CLI. Check: scripts/herdr-stub.test.sh asserts help parity and socket shapes; scripts/test.

- [ ] TASK-HDR-006 [complex] Implement the herdr backend per design Decisions 6, 7 and 10: dedicated server/config, scrubbed env, labelled panes created only via local-socket layout.apply after the socket check (all else CLI), recorder, process-bound liveness, lifecycle fallback, read-only refusal, agent status; refuse agents failing gate (e). Ship backend and recorder. Check: HDR-014 fake covers config/env, socket refusal, lost reply, restart, unknown liveness; scripts/test.

- [ ] TASK-HDR-007 [standard] Make nudge and send --verify capability-aware per design Decision 8: unchanged with capture attributes; without them, a Claude box holding text is unknown, nudge without --message submits nothing, and the replacement check (herdr reports working or the box no longer holds the text) verifies, else one retry then fail; Codex unchanged. Check: extend scripts/session-nudge-placeholder.test.sh with herdr-stub variants, tmux cases unchanged, full scripts/test green.

- [ ] TASK-HDR-008 [routine] Add the session list AGENT_STATUS column per design Decision 9: herdr status for live herdr records via one bounded read-only query per listing, `-` for tmux, terminal or unsupported records, unknown on query failure without failing the listing. Check: a mixed-listing case in scripts/session-backend-herdr.test.sh, list expectations changed only for the new column, full scripts/test green.

## 5. Setup and diagnostics

- [ ] TASK-HDR-009 [standard] Add the conditional, read-only herdr doctor checks per design Decision 12, including binary/recorder failures, version warnings, reachability and records-only notes, and accurate restart guidance. Check: doctor-herdr tests cover unused, FAIL, WARN and restart NOTE cases; scripts/test.

- [ ] TASK-HDR-010 [standard] Write docs/using-with-herdr.md (experimental; every topic in the session-backends guide requirement) and update running-work-in-sessions, operating-model, architecture, security-model, failure-recovery, compatibility (herdr 0.9.x optional row), README, AGENTS.md and the three launch prompts to backend-neutral wording; ship the guide. Check: scripts/test green (docs, installation, security, package-manifest suites), links resolve, orchestrator-on-tmux stated.

## 6. Verification and acceptance

- [ ] TASK-HDR-011 [standard] Add the end-to-end suite scripts/session-herdr.test.sh via scripts/nogg on the HDR-014 fake herdr: launch (record before exec, one socket layout.apply with recorder argv, redaction), unsafe-socket refusal, mixed list, send, nudge, kickoff, stop, reap after pane loss and restart, cleanup (orphan panes closed, server kept), attach, reservation probe, orchestrator on tmux, packed install. Check: suite and full scripts/test green, inherited NOGG_* unset.

- [ ] TASK-HDR-012 [complex] Real Pi acceptance on herdr 0.9.x: one --backend herdr Lead session each for Claude, Codex and Antigravity through send, nudge (with and without --message), log, agent_status, stop, simulated server restart, reap, cleanup and exact resume, plus one parallel tmux Lead regression; write docs/acceptance/<date>-herdr-backend.md from the template, unsigned with an empty Signed-off-by line. Check: report committed unsigned, scripts/test green, doctor shows herdr.

## Independent Codex compatibility fix

- [x] TASK-HDR-013 [standard] Fix Codex CLI launch compatibility: omit `--add-dir` for read-only launches and reject unsupported `ask_for_approval` values during preflight. Applies to tmux and herdr; independent of herdr tasks. Check: launcher tests cover read-only and supported/unsupported values; scripts/test.

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` = A depends on B): 002<-001, 003<-002, 004<-001, 005<-001, 006<-003, 006<-004, 006<-005, 006<-014, 007<-006, 008<-006, 009<-003, 009<-004, 009<-005, 010<-003, 011<-006, 011<-007, 011<-008, 011<-014, 012<-009, 012<-010, 012<-011, 014<-005. TASK-HDR-013 has no dependency on the herdr tasks. The parallel lanes are {002, 004, 005} after 001, {009, 010} after 003, 014 after 005 (alongside 009 and 010), and {007, 008} after 006; HDR-013 is independent. TASK-HDR-014 was added by the 2026-10-15 transport revision (discovery SPEC-ypyo) and must land before 006 so that no test passes against an unverified herdr interface. If TASK-HDR-001 records a blocking discovery, no dependent task proceeds and the change returns to planning. Each task's full contract is its design Decision plus the session-backends requirements it names.

## Execution contract

The Main Worker claims every task and implements it only in its own allocated worktree. Before allocating a dependent worktree, verify that every prerequisite execution commit is integrated into develop; Bead closure alone is not enough. Run each task's named checks before closing it, then run bd close, immediately run scripts/nogg task-done, commit the execution change and the mapped tick together with the real Bead ID, and append the SHA and evidence. Agents never hand-edit OpenSpec. Discoveries carry the discovery label and prose. Nobody signs human acceptance.
