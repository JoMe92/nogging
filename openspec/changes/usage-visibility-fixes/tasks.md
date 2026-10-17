## 1. Independent fixes (fix/, test/, feat/, chore/ — parallel, no prerequisites)

- [x] TASK-UVF-001 [standard] Per design Decisions 1-2 (#211 problem 1): keep a Codex observation valid until each window's `resets_at` (no `stale_after` expiry for Codex), mark it `stale`, show its age in `nogg usage`, update the Codex doctor note and the superseded stale assertions. Own the Codex branch of `inspect_usage()` and the Codex region of `quota_freshness_notes()`. Branch fix/. Check: scripts/usage.test.sh; scripts/usage-gate.test.sh; scripts/test.

- [ ] TASK-UVF-002 [routine] Per design Decisions 1 and 3 (#211 problem 2): separate the no-model reason from the unrecognised-model reason in `agy_select_group()` (keep the `unknown model mapping` prefix), add a model-selection-table drift guard and a `--tier` launch assertion, and document that bare agy usage needs `--model`. Own `agy_select_group()` and `docs/using-with-antigravity.md`. Branch test/. Check: scripts/antigravity-usage.test.sh; scripts/packed-antigravity-usage.test.sh; scripts/test.

- [ ] TASK-UVF-003 [routine] Per design Decisions 1 and 4 (#211 problem 3): add the advisory window `hint` (Claude missing source → `run nogg usage install-statusline`), carry it through `evaluate_gate()`, print it in `nogg usage`, and prove the Claude doctor note names it. Do not edit `usage_gate_admission()`. Branch feat/. Check: scripts/usage-hints.test.sh (new); scripts/usage-gate.test.sh; scripts/test.

- [x] TASK-UVF-004 [standard] Per design Decisions 1 and 5 (#211 problem 4): keep `on_unknown: warn`; make the unknown-admitted launch warning a prominent WARN (keep the `usage is unknown (<bucket>: <reason>` substring, append any window `hint`) and add the `unknown_policy_notes()` doctor NOTE. Own the `unknown-admitted` print in `usage_gate_admission()`. Branch chore/. Check: scripts/usage-unknown-visibility.test.sh (new); scripts/usage-gate.test.sh; scripts/test.

## Dependency contract

No blocking edges: UVF-001..004 are independent and run in parallel. Markdown
order does not block work. Branches are <prefix>/usage-visibility-fixes with
each task's prefix above (fix/, test/, feat/, chore/); each uses its own
worktree. The only cross-task contract is the optional window `hint` field:
UVF-003 produces it, UVF-004 reads it with `.get`, so either may merge first.
Whoever merges second re-runs scripts/usage-gate.test.sh and confirms the
launch WARN shows the Claude hint. A blocking `unknown` default is out of scope
(Product Owner decision).
