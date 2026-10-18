## 1. Launch-name safety (#235)

- [x] TASK-LCD-001 [standard] Per design Decisions 1-2: add shared safe_session_name ('.' and ':' to '_'), use it for generated and orchestrator names, make tmux and herdr prepare/start refuse an unsafe name before any side effect, herdr labels equal the record name. Branch fix/. Check: new scripts/session-name-safety.test.sh (red on develop first); scripts/test.

- [x] TASK-LCD-002 [standard] Per design Decisions 1 and 3: tmux and herdr start() undo their own half-created session or pane; _session_launch removes the known backend session on any failure from start() through settle_launch, records failed with the cleanup outcome, never kill-server, and keeps a running session after a kickoff refusal. Branch refactor/. Depends on LCD-001. Check: new scripts/session-launch-cleanup.test.sh (red first); scripts/test.

## 2. Codex delivery (#236, SPEC-t374, HPS-007 step 3)

- [ ] TASK-LCD-003 [standard] Per design Decisions 1 and 4: accept exactly one '[Pasted Content N chars]' token as this operation's own pending paste on a verified-empty composer for a long or multi-line message, shared by send, nudge and kickoff, including the real 866-character planning kickoff; refuse foreign, repeated, pre-existing or image cases. Branch feat/. Check: new scripts/session-codex-paste-placeholder.test.sh (red first); related existing suites green; scripts/test.

- [ ] TASK-LCD-004 [standard] Per design Decisions 1 and 5: add a pure Codex turn_state reader, record whether a launch passed a startup prompt, gate Codex kickoff readiness on a completed startup turn, and press Enter for Codex only while the turn is not running, failing honestly at the deadline. Branch chore/. Check: new scripts/session-codex-startup-turn.test.sh (red first); readiness, kickoff and receipt suites green; scripts/test.

- [ ] TASK-LCD-005 [standard] Per design Decisions 1 and 6: before 'codex queue' require an idle pane, backend status and turn_state; poll to idle or the delivery deadline, then refuse without invoking the queue; keep receipt-only success and the never-requeue unverified error with thread prefix and scan outcome; nudge --message follows. Branch perf/. Depends on LCD-004. Check: new scripts/session-codex-queue-busy.test.sh (red first); queue suite green; scripts/test.

## 3. Planner process identity (HPS-007 step 4)

- [ ] TASK-LCD-006 [standard] Per design Decisions 1 and 7, diagnostic first: reproduce with a failing test that a tmux session started from a caller whose /proc cannot see the pane PID gets null session_pid_start/ns and cannot take the planning lock; then use a wrapper receipt and refuse an unprovable planning launch after cleanup; if not reproducible, document it. Branch fix/. Depends on LCD-002. Check: new scripts/session-pid-identity.test.sh; scripts/test.

## 4. Guidance (docs/)

- [ ] TASK-LCD-007 [routine] Per design Decisions 1 and 9: document in running-work-in-sessions, using-with-codex and failure-recovery what #207, #216 and #218 fixed and that an older vendored copy needs update, the safe-name rule and no-orphan launch failure, the Codex placeholder, startup-turn gate, busy-Codex refusal and the planner identity outcome; add a CHANGELOG Unreleased entry. Branch docs/. Depends on LCD-001 to LCD-006. Check: extend scripts/session-delivery-docs.test.sh; scripts/test.

## 5. Delivery-host acceptance (test/, host-capable Lead)

- [ ] TASK-LCD-008 [complex] Per design Decisions 1 and 9: in a scratch consumer on private sockets, touching no fleet session, probe a dotted-Bead launch with an induced start failure, Codex placeholder N versus length, busy send, first-turn Enter, Tab-to-queue and a planner launched from a fenced caller; record versions and honest outcomes in an unsigned report. Branch test/. Depends on LCD-007. Check: docs/acceptance/<date>-launch-name-codex-delivery.md, empty Signed-off-by; scripts/test.

## Dependency contract

Explicit blocking edges (`A <- B` means A depends on B):
LCD-002<-LCD-001; LCD-005<-LCD-004; LCD-006<-LCD-002;
LCD-007<-LCD-001,LCD-002,LCD-003,LCD-004,LCD-005,LCD-006; LCD-008<-LCD-007.
LCD-001, LCD-003 and LCD-004 have no prerequisites and run in parallel. Markdown
order does not block work. Before allocating a dependent worktree, verify every
prerequisite execution commit has reached develop, not merely that its Bead is
closed. The still-unarchived reliable-session-input change is already
implemented on develop; no external edge is needed.

Branches are <prefix>/launch-name-codex-delivery. Seven valid branch types exist
for eight tasks, so LCD-006 reuses fix/ only after LCD-001's branch is
integrated and deleted (guaranteed by LCD-006<-LCD-002<-LCD-001); every other
prefix is distinct.

## Failing-first detail (titles stay short; this section is the contract)

- LCD-001: a stateful tmux fake that rewrites '.'/':' in session names and
  parses '-t' like tmux, driving the real 'session launch' CLI for Bead
  'supply-doc-v0zu.1' with stub agents from scripts/lib/test-agents.sh; plus
  the herdr stub for labels.
- LCD-002: pipe-pane failing after new-session, settle_launch raising, an
  exception before the running transition, and a herdr start failure after the
  pane exists; each leaves an orphan on develop. A kickoff refusal after
  'running' must leave the session.
- LCD-003: a stateful Codex composer fake that collapses a message of 200+
  characters or any newline into '[Pasted Content N chars]'; drive the real
  _deliver_pane_locked, nudge and kickoff paths, using the exact text
  _kickoff_message composes for a planning session (866 characters in the
  HPS-007 run) and a ~1074-character message (SPEC-t374). Today: 'the composer
  did not hold exactly the message'.
- LCD-004: a synthetic rollout where the composer is empty and steady before
  task_started, and a composer that swallows Enter while the turn is running;
  resume and no-prompt launches keep today's rule.
- LCD-005: a PATH 'codex' stub whose 'queue' exits 0 and appends nothing,
  against a busy pane and rollout, asserting it is never called; plus
  idle-with-receipt, becomes-idle-in-time and accepted-without-evidence (queue
  count one, nothing typed). Run the real _codex_queue_invoke; never patch run.
- LCD-006: model the foreign PID namespace by making the launcher's identity
  reads fail for the backend-reported pane PID (no unshare, no PID-range
  assumption); assert the record, then that plan-begin in that session context
  is refused; then the wrapper-receipt and planning-refusal behaviour.

## Execution contract

The Main Worker claims exactly its authorized Bead and reads Decision 1, the
task's named Decisions and the matching requirements before coding. Commit the
failing suite first and record its red output in the Bead note, then the fix.
Suites run the real delivery and launch code (never _is_legacy_mock) with
stateful fakes and scripts/lib/test-agents.sh stubs (write a test's own codex
stub before calling stub_agent_binaries); CI has no codex, agy, claude, tmux
server, herdr, Dolt or bd. Honor the AGENTS validation, close, task-done,
commit and evidence protocol and the active session authority. Execution agents
never hand-edit OpenSpec or sign human acceptance. Record discoveries with the
native label and prose. Tasks 001-007 suit Codex or Antigravity Leads; 008
requires a host-capable supervised session. Planning grants no push authority
and no live-fleet input.
