## 1. Independent foundations (fix/, feat/, refactor/)

- [x] TASK-RSI-001 [standard] Per design Decisions 1-2: implement unique tmux stdin paste buffers, bracketed paste with LF preservation and failure cleanup; retain fenced argv and no transport Enter. Update runner stdin forwarding and primitive docs. Branch fix/. Depends on SPEC-culj. Check: scripts/session-paste-transport.test.sh; scripts/test.

- [x] TASK-RSI-002 [standard] Per design Decisions 1 and 3: validate timing keys and add bounded runtime readiness; replace AGY's fixed first-turn wait with current Stop or two exact-process idle/empty samples, with timeout diagnostics and no speculative input. Own readiness functions only. Branch feat/. Check: scripts/session-input-ready.test.sh; scripts/test.

- [x] TASK-RSI-004 [standard] Per design Decisions 1 and 5: add pure exact-thread incremental Codex user-message receipt reader with source snapshots, partial-line handling, bounded reads and unknown outcomes; ship module via installer manifest without persisting transcript text. Branch refactor/. Check: scripts/session-codex-receipt.test.sh including scratch init/update; scripts/test.

## 2. Delivery integration (fix/, sequential)

- [x] TASK-RSI-003 [standard] Per design Decisions 1 and 4: reuse HSS clear/exact helpers; serialize pane delivery, verify by default, wait before one Enter and retry once only for owned pending input; plain send refuses existing or unknown input. Branch fix/. Depends on RSI-001, RSI-002 and SPEC-culj. Check: scripts/session-submit-policy.test.sh; scripts/session-nudge-clear.test.sh; scripts/test.

- [x] TASK-RSI-005 [standard] Per design Decisions 1 and 6: integrate Codex queue outcomes and fresh receipts into send/nudge; recover exact queued composer text without retyping, fail accepted-but-unverified, and forbid ambiguous fallback or requeue. Branch fix/. Depends on RSI-003, RSI-004 and SPEC-culj. Check: scripts/session-codex-queue-delivery.test.sh; scripts/test.

- [x] TASK-RSI-006 [standard] Per design Decisions 1 and 7: wire every kickoff and launch --kickoff through readiness and verified delivery; serialize attempts, preserve role scope and persist hash/receipt identity so ambiguous repeats cannot duplicate input. Branch fix/. Depends on RSI-002 and RSI-005. Check: scripts/session-kickoff-delivery.test.sh; scripts/test.

## 3. Operator guidance and installed regression (docs/ and test/, parallel)

- [ ] TASK-RSI-007 [routine] Per design Decisions 1 and 8: document timing keys, verified sends, queue acceptance versus submission, startup/hook diagnosis and deliberate recovery in session, Codex, AGY and failure-recovery guides; leave old reports and restart paragraphs unchanged. Branch docs/. Depends on RSI-006. Check: scripts/session-delivery-docs.test.sh; scripts/test.

- [x] TASK-RSI-008 [standard] Per design Decisions 1 and 8: add installed-consumer CLI regression for both backend fakes and three agents, init/update packaging, slow startup, queued drafts, multiline HSS replacement, no duplicates and unchanged Pi delivery. Branch test/. Depends on RSI-006. Check: scripts/session-delivery-integration.test.sh; scripts/test.

## 4. Delivery-host acceptance (docs/, host-capable Lead)

- [ ] TASK-RSI-009 [complex] Per design Decisions 1 and 9: run disposable Claude/Codex/AGY delivery acceptance on both backends, slow and multiline kickoff, queue receipts, repeated attempts and startup failures; record versions and honest outcomes in an unsigned dated report, touching no fleet sessions. Branch docs/. Depends on RSI-007 and RSI-008. Check: docs/acceptance/<date>-reliable-session-input.md with empty Signed-off-by; scripts/test.

## Dependency contract

Explicit blocking edges (`A <- B` means A depends on B):
RSI-001<-SPEC-culj; RSI-003<-RSI-001,RSI-002,SPEC-culj;
RSI-005<-RSI-003,RSI-004,SPEC-culj; RSI-006<-RSI-002,RSI-005;
RSI-007<-RSI-006; RSI-008<-RSI-006; RSI-009<-RSI-007,RSI-008.
RSI-002 and RSI-004 have no prerequisites. Markdown order does not block work.
The external SPEC-culj edges remain even if that Bead is already closed.
Before allocating any dependent worktree, verify every prerequisite execution
commit has reached develop, including SPEC-culj's HSS-005 implementation.

Branches are <prefix>/reliable-session-input with each task's prefix above.
Reuse fix/ sequentially (001, 003, 005, 006) and docs/ sequentially (007, 009),
only after the previous branch is integrated and deleted. Initial parallel
lanes are 002 feat/, 004 refactor/, and 001 fix/ after HSS-005 integration.
After 006, docs/ 007 and test/ 008 can run concurrently. Tasks 001-008 suit
Codex or Antigravity Leads; 009 requires a host-capable supervised session.

## Execution contract

The Main Worker claims exactly its authorized Bead. Read Decision 1, the
task's named Decisions and matching capability requirements before coding.
No real Dolt/bd, PID assumptions, unshare, existing tmux server or live-fleet
input in CI. Honor the AGENTS validation/close/task-done/commit/evidence
protocol and active session authority. Use a Conventional Commit with the
real Bead ID; Main Worker retains claim, closure and commit responsibilities.
Execution agents never hand-edit OpenSpec or sign human acceptance. Record
discoveries with the native label and prose; preserve in-progress breadcrumbs.
This planning run grants no additional runtime permissions or push authority.
