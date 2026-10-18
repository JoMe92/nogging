## 1. Writer-side rebase (#241)

- [ ] TASK-SLR-001 [complex] Per design Decisions 1-5 (abort on any conflict for now): add `nogg worktree rebase [<record>]` for an unfenced caller: implementation records via canonical state, ordered refusals, up-to-date no-op, journal, backup ref, rebase, post-verify, Lead identity kept. Branch fix/. Check: new scripts/worktree-rebase.test.sh with real git fixtures (bare origin, linked worktree, upstream tasks.md tick and archive rename), red first; scripts/test.

- [ ] TASK-SLR-002 [standard] Per design Decision 5 conflict policy: an openspec/ conflict aborts and proves the tree equals the previous state; a code-only conflict leaves a real paused rebase (journal paused, exit 3); add writer-side `--continue` and `--abort`, refusing when nothing is paused. Branch refactor/. Depends on SLR-001. Check: new scripts/worktree-rebase-conflict.test.sh (red first); worktree-rebase suite green; scripts/test.

## 2. Fenced Lead access

- [ ] TASK-SLR-003 [complex] Per design Decisions 2 and 6: a fenced caller never runs git and sends the closed rebase request (start|continue|abort, session) to the sandbox broker; extend scripts/openspec-sandbox with that shape and a `rebase-broker` contract feature, task-done unchanged; an old or missing broker gives the hand-off message. Branch chore/. Depends on SLR-001, SLR-002. Check: new scripts/worktree-rebase-broker.test.sh (real handler, PATH git shim, red first); scripts/test.

## 3. Detection and repair

- [ ] TASK-SLR-004 [standard] Per design Decision 7: add the pure read-only classifier (clean, operation-in-progress, half-applied, mixed, dirty) by byte equality with origin/develop blobs; reuse it in the rebase refusal text and in doctor (NOTE) and recover (attention) with stale-journal reporting; hint is path-scoped restore/clean, never reset --hard. Branch feat/. Check: new scripts/worktree-integrity.test.sh synthesising the #241 state plus mixed and dirty cases (red first); scripts/test.

- [ ] TASK-SLR-005 [standard] Per design Decision 8: add `nogg worktree repair <record> [--apply]`, dry-run by default; --apply snapshots the whole dirty state to refs/nogg/repair-backup via a temporary index, restores only proven-reproducible paths, refuses an operation in progress or a live foreign session; fenced --apply refuses openspec/ paths. Branch perf/. Depends on SLR-004. Check: new scripts/worktree-repair.test.sh proving own edits survive byte for byte (red first); scripts/test.

## 4. Stop the damage at the source

- [ ] TASK-SLR-006 [standard] Per design Decision 9: add scripts/hooks/pre-rebase (fenced or read-only openspec/ plus an upstream diff touching openspec/ exits 1 before any write), install it via scripts/install-hooks and the payload manifest, and add the one rule to the no-autonomous-claim and autonomous prompts. Branch test/. Depends on SLR-003. Check: new scripts/pre-rebase-guard.test.sh with real git rebase and pull --rebase (red first); scripts/test.

## 5. Guidance (docs/)

- [ ] TASK-SLR-007 [routine] Per design Decisions 2-10: document in running-work-in-sessions, failure-recovery, operating-model and architecture who runs the rebase, the refusals, conflict policy, half-applied hint and repair, the pre-rebase delivery limit, the push-after-rebase note and a host recipe for a real read-only mount; add a CHANGELOG Unreleased entry. Branch docs/. Depends on SLR-001 to SLR-006. Check: extend scripts/runtime-guidance-docs.test.sh; scripts/test.

## Dependency contract

Explicit blocking edges (`A <- B` means A depends on B):
SLR-002<-SLR-001; SLR-003<-SLR-001,SLR-002; SLR-005<-SLR-004; SLR-006<-SLR-003;
SLR-007<-SLR-001,SLR-002,SLR-003,SLR-004,SLR-005,SLR-006.
SLR-001 and SLR-004 have no prerequisites and run in parallel. Markdown order does
not block work. Before allocating a dependent worktree, verify every prerequisite
execution commit has reached develop, not merely that its Bead is closed.

Branches are <prefix>/safe-lead-rebase. The seven tasks use seven distinct valid
branch types (fix, refactor, chore, feat, perf, test, docs), so no branch name is
reused and any subset can run concurrently.
