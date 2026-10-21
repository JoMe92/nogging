## 1. Verified integration contract

- [ ] TASK-DRO-001 [complex] Decision 1: retest the revised contract after explicit operator trust setup and post-setup baselines; prove retained rules, allowed commands, native/Happier exact resume, sanitized input and complete stop. Check: honest unsigned evidence with unchanged global policies; missing prerequisites remain blocked. Branch docs/.

## 2. Runtime selection and native lifecycle

- [ ] TASK-DRO-002 [standard] Decision 2: add canonical selection/checkpoint state and orchestrator start; preflight exact repository/config-layer trust before any runtime spawn, validate agent/control and refuse live switching. Check: defaults, unknown trust, no implicit global trust writes, service errors and concurrent-start fixtures. Depends on DRO-001. Branch feat/.

- [ ] TASK-DRO-003 [complex] Decision 3: ship the Codex host-access profile with execpolicy retained, role-scoped fence exemption and honest HOST-ACCESS label; preserve Claude FULL-ACCESS and ordinary-role boundaries. Check: effective policy/model/effort, sentinel denial plus allowed command, no rule bypass or global edits, helper contracts. Depends on DRO-002. Branch feat/.

- [ ] TASK-DRO-004 [complex] Decision 4: generalize supervisor, adoption, stop and restart with verified ownership and exact per-selection checkpoints; cold recovery must preflight trust. Check: provider recovery, legacy migration, exact-ID errors, supervisor-only adoption, switch-back, unknown ownership and stop timeout. Depends on DRO-003. Branch feat/.

## 3. Happier access and installed operations

- [ ] TASK-DRO-005 [complex] Decision 5: implement tmux-owned Codex/Happier control with allowlisted environment, own first input and attributable IDs; reconcile explicit remote stop with owned PID/start-time termination. Check: contaminated parent, exact resume, stale activity, API/auth/version/receipt failures, no fallback or duplicate send. Depends on DRO-004. Branch feat/.

- [ ] TASK-DRO-006 [standard] Decision 6: ship diagnostics/status JSON, runtime-specific authority/floor/trust state, payloads and Codex entry point; document explicit trust setup, denied-action escalation and recovery. Check: packed init/update/remove, preserved state/custom files, no-systemd and Claude without Happier. Depends on DRO-005. Branch docs/.

## 4. Integration and acceptance

- [ ] TASK-DRO-007 [standard] Decision 8: cover trust refusal before spawn, global-config immutability, sanitized initial input, retained floor, authority labels, exact recovery and local/remote stop agreement. Check: focused orchestrator/session/helper/delivery/floor/packaging suites and one isolated full scripts/test. Depends on DRO-006. Branch test/.

- [ ] TASK-DRO-008 [complex] Decision 8: run the three-selection host matrix after explicit trusted-fixture setup and baseline capture; prove exact resume, owned mobile round trip, restart/adoption, switching and complete stop. Check: dated unsigned evidence with policy immutability and honest authority; report missing prerequisites as blocked. Depends on DRO-007. Branch test/.

## Dependency contract

Explicit Beads edges (`A <- B`): 002<-001, 003<-002, 004<-003, 005<-004, 006<-005, 007<-006, 008<-007. TASK-DRO-001 remains blocked from its earlier run until explicit operator fixture preparation and the revised contract are satisfied; revising the plan does not mark it ready or complete. All eight mappings and the seven dependency edges are reconciled in place. See design Decision 7 for lanes and integration prerequisites. All branches use the slug dual-runtime-orchestrator. These tasks are materialized unclaimed; implementation begins only in a separate authorized execution session.

## Execution contract

Read the assigned design Decision and matching delta requirements. Main Workers claim the named Bead, keep execution OpenSpec read-only, validate the task, then follow AGENTS.md close -> task-done -> one Conventional implementation commit bundling the tick -> SHA/evidence note. Record material discoveries with the discovery label and prose; a contract-blocking finding stops its dependent chain for planning review. Run real probes only in the disposable host-authorized scope specified by the task. Never sign human acceptance or infer successful acceptance from a stubbed test.
