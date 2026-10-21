## 1. Verified integration contract

- [ ] TASK-DRO-001 [complex] Per design Decision 1, verify native Codex and tmux-owned Happier/Codex cold start, exact thread plus remote-ID receipt, effective role-scoped authority, exact resume and complete stop in a host-authorized disposable repository; record versions, supported arguments and redacted evidence in docs/acceptance/<date>-orchestrator-runtime-contract.md with empty Signed-off-by. Check: observed owned process and remote identities agree, inert round trip succeeds, unrelated sessions survive, and stopping leaves no owned live remote agent; an unsupported contract is a blocking discovery. Branch docs/.

## 2. Runtime selection and native lifecycle

- [ ] TASK-DRO-002 [standard] Per design Decision 2, add canonical versioned selection/checkpoint state and orchestrator start with agent/control validation, explicit/saved/default precedence, idempotent matching starts, service installation/re-enable and refusal to switch a live or unknown owner. Check: focused stubbed tests cover defaults, unsupported pairs, corrupt state, linked checkouts, missing prerequisites and concurrent starts without touching real services. Depends on DRO-001. Branch feat/.

- [ ] TASK-DRO-003 [complex] Per design Decision 3 and launch-profiles deltas, ship the Codex orchestrator profile, scoped effective authority and native launcher path using the verified runtime contract; forward model/effort and shared persona, permit the exception only for the explicit orchestrator role/profile and preserve other roles and shared/global policies. Check: native launch/resume argv and actual-policy receipt fixtures, ordinary-role/profile refusal or normalization, source/global-file immutability, helper-contract and floor/fence regressions. Depends on DRO-002. Branch feat/.

- [ ] TASK-DRO-004 [complex] Per design Decision 4, generalize supervisor/adoption/stop/restart to the saved runtime/control and per-selection exact checkpoints; require verified ownership, reject recordless or mismatched adoption, retain canonical singleton/cross-namespace rules and self-restart guard, and preserve own conversation across stop/switch-back. Check: fake-runtime lifecycle tests for both native providers, crash/reboot-equivalent recovery, supervisor-only adoption, exact-ID errors, legacy Claude migration, stop timeout and switch refusal while liveness is unknown. Depends on DRO-003. Branch feat/.

## 3. Happier access and installed operations

- [ ] TASK-DRO-005 [complex] Per design Decision 5, implement the verified Codex/Happier adapter within the managed tmux lifecycle; record attributable remote/session IDs, propagate authority/persona/model/effort, expose remote readiness, verify message receipt and ensure stop covers the owned local and remote runtime. Check: stubbed registration/resume/delivery/stop tests include API outage, auth failure, unsupported versions, detached surviving process, ambiguous receipt and unrelated Happier sessions; no automatic resend, fallback, duplicate agent or transcript deletion. Depends on DRO-004. Branch feat/.

- [ ] TASK-DRO-006 [standard] Per design Decision 6, integrate runtime/control/ownership/readiness diagnostics and versioned status JSON, session inspection/delivery and honest usage attribution; ship all profile/helper/prompt payloads and Codex orchestration entry point; update lifecycle, installation, AGENTS and security/recovery guidance. Check: packed fresh init/update/remove and no-systemd cases, preserved stopped selection/checkpoints/custom files, native Claude without Happier, JSON/doctor/recover/session-list consistency and documentation command parity. Depends on DRO-005. Branch docs/.

## 4. Integration and acceptance

- [ ] TASK-DRO-007 [standard] Per design Decision 8, complete cross-runtime regression coverage for concurrent singleton claims, role authority isolation, exact recovery, native/Happier failure boundaries and packed payloads; reconcile packed orchestrator fence fixtures with the role contract without weakening execution checks. Check: focused orchestrator, canonical-lock, session, helper-contract, floor/fence, delivery and packaging suites plus one full scripts/test with isolated HOME/state and no real Beads/services. Depends on DRO-006. Branch test/.

- [ ] TASK-DRO-008 [complex] Per design Decision 8, perform the Claude/native, Codex/native and Codex/Happier scratch-host lifecycle matrix: startup/persona, verified remote round trip where configured, own exact recovery, full and supervisor-only restart, linked-checkout stop, repeated stop, switch/switch-back, duplicate refusal and preservation of unrelated sessions; prove no owned remote runtime survives stop. Check: dated redacted docs/acceptance/<date>-dual-runtime-orchestrator.md includes versions, process/remote identity evidence and pass/fail/skipped/unknown outcomes with blank Signed-off-by; report actual reboot separately from reboot-equivalent recovery. Depends on DRO-007. Branch test/.

## Dependency contract

Explicit Beads edges (`A <- B`): 002<-001, 003<-002, 004<-003, 005<-004, 006<-005, 007<-006, 008<-007. Only TASK-DRO-001 is initially ready. See design Decision 7 for lanes and integration prerequisites. All branches use the slug dual-runtime-orchestrator. These tasks are materialized unclaimed; implementation begins only in a separate authorized execution session.

## Execution contract

Read the assigned design Decision and matching delta requirements. Main Workers claim the named Bead, keep execution OpenSpec read-only, validate the task, then follow AGENTS.md close -> task-done -> one Conventional implementation commit bundling the tick -> SHA/evidence note. Record material discoveries with the discovery label and prose; a contract-blocking finding stops its dependent chain for planning review. Run real probes only in the disposable host-authorized scope specified by the task. Never sign human acceptance or infer successful acceptance from a stubbed test.
