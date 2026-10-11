## 1. Profile selection and validation

- [x] TASK-CRE-001 Implement Claude profile effort and session launch --effort precedence; preserve Codex and reject cross-agent inputs. Verify all five levels, omission, invalid inputs even when overridden, configured-agent resolution and refusal before worktree/settings/record/tmux side effects. See design decisions 1–2 and delta selection requirement.

## 2. Native transport and helper compatibility

- [ ] TASK-CRE-002 Forward native Claude --effort on cold/exact-resume launches; strip the Nogging key from effective settings and add wrapper validation, contract capability and doctor checks. Verify exact argv, empty-input refusal, stale-helper refusal, native failure propagation and unchanged authority/profile/global state; preserve Codex. Depends on TASK-CRE-001; see design decision 3 and delta transport requirement.

## 3. Provenance and operator guidance

- [ ] TASK-CRE-003 Add reasoning_effort_source and backward-compatible record/list rendering for Claude/Codex; document custom profile JSON, override/default behavior, CLI version and limitations in session guidance/architecture. Verify launch/profile/default/Codex/legacy cases, other-agent display and examples. Depends on TASK-CRE-002; see design decision 4 and delta provenance requirement.

## 4. Installed and live verification

- [ ] TASK-CRE-004 Verify packed init/update effort selection, contracts, argv, provenance, defaults and global/profile preservation plus other-agent regressions. Run scripts/test with inherited session env cleared and CI fixtures without bd; perform bounded real-Claude acceptance with isolated config/inert prompt and unsigned version/model/level evidence. Quota/auth blocks acceptance. Depends on TASK-CRE-003; see design decision 5 and all delta scenarios.
