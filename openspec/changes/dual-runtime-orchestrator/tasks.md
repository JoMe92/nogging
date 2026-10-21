## 1. Verified integration contract

- [ ] TASK-DRO-001 [complex] Design Decision 1: prove native Codex and tmux-owned Happier/Codex identity, authority, exact resume and complete stop in an isolated host-authorized scratch scope. Check: dated unsigned runtime-contract report with versions, verified round trip and no surviving owned remote agent; unsupported contracts block. Branch docs/.

## 2. Runtime selection and native lifecycle

- [ ] TASK-DRO-002 [standard] Design Decision 2: add canonical versioned selection/checkpoint state and orchestrator start with validated agent/control, saved defaults, service enable/start and live-switch refusal. Check: isolated tests for precedence, corrupt state, linked checkouts, prerequisites and concurrent starts. Depends on DRO-001. Branch feat/.

- [ ] TASK-DRO-003 [complex] Design Decision 3 and launch-profiles deltas: ship scoped Codex orchestrator authority, native launcher, shared persona and model/effort forwarding without weakening other roles or shared policies. Check: launch/resume and effective-policy fixtures, role/floor/fence isolation and helper contracts. Depends on DRO-002. Branch feat/.

- [ ] TASK-DRO-004 [complex] Design Decision 4: generalize native supervisor, adoption, stop and restart with verified ownership and per-selection exact checkpoints. Check: both-provider crash/reboot-equivalent recovery, legacy migration, exact-ID failure, supervisor-only adoption, switch-back and stop-timeout tests. Depends on DRO-003. Branch feat/.

## 3. Happier access and installed operations

- [ ] TASK-DRO-005 [complex] Design Decision 5: implement tmux-owned Codex/Happier control with attributable IDs, effective policy, readiness, verified delivery and complete remote/local stop. Check: outage/auth/version/receipt/stop fixtures, detached survivors, no fallback or duplicate send, unrelated sessions untouched. Depends on DRO-004. Branch feat/.

- [ ] TASK-DRO-006 [standard] Design Decision 6: integrate diagnostics/status JSON, runtime inspection/delivery, honest usage attribution, installed payloads, Codex entry point and operations/security/AGENTS guides. Check: packed init/update/remove, preserved checkpoints/custom files, no-systemd and Claude without Happier. Depends on DRO-005. Branch docs/.

## 4. Integration and acceptance

- [ ] TASK-DRO-007 [standard] Design Decision 8: complete cross-runtime singleton, authority, exact-recovery, transport and packed-payload regression coverage; reconcile orchestrator fence fixtures. Check: focused orchestrator/session/delivery/floor/helper/packaging suites and one isolated full scripts/test. Depends on DRO-006. Branch test/.

- [ ] TASK-DRO-008 [complex] Design Decision 8: run the three-selection scratch-host lifecycle matrix, verified remote round trip, own exact recovery, restart/adoption, linked stop, repeat stop, switch-back and singleton preservation. Check: dated redacted unsigned dual-runtime acceptance report; distinguish actual reboot from equivalent checks. Depends on DRO-007. Branch test/.

## Dependency contract

Explicit Beads edges (`A <- B`): 002<-001, 003<-002, 004<-003, 005<-004, 006<-005, 007<-006, 008<-007. Only TASK-DRO-001 is initially ready. See design Decision 7 for lanes and integration prerequisites. All branches use the slug dual-runtime-orchestrator. These tasks are materialized unclaimed; implementation begins only in a separate authorized execution session.

## Execution contract

Read the assigned design Decision and matching delta requirements. Main Workers claim the named Bead, keep execution OpenSpec read-only, validate the task, then follow AGENTS.md close -> task-done -> one Conventional implementation commit bundling the tick -> SHA/evidence note. Record material discoveries with the discovery label and prose; a contract-blocking finding stops its dependent chain for planning review. Run real probes only in the disposable host-authorized scope specified by the task. Never sign human acceptance or infer successful acceptance from a stubbed test.
