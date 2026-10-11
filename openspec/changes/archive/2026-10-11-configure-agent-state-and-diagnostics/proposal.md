## Why

Several host adjustments that a new Nogging system currently needs by hand belong in Nogging itself (Product Owner request, 2026-10-10):

- A Codex session that runs live Antigravity (`agy`) probes needs the Antigravity runtime state directory writable. Today that is only possible with the per-launch environment variable `NOGG_CODEX_EXTRA_WRITABLE_ROOTS` (interim mechanism from SPEC-e7oa, explicitly "to be replaced by config-driven agent state roots").
- Whether a Codex session can write the shared and per-worktree Git directories, fetch over SSH and run `scripts/test` inside its sandbox (the SPEC-9085 / SPEC-2e64 failure classes) is only discovered when a supervised worker fails.
- The Product Owner's interactive Orchestration Agent sessions need a permission configuration whose limits (auto-mode classifier, user-only `autoMode`) are not written down anywhere.
- The owner-requested autonomous Claude configuration (SPEC-u57h, commit 1ae9dab, already integrated) has no approved OpenSpec task, so its Bead cannot be closed through `task-done`.

## What Changes

- Add a validated `agent_state_roots` configuration key that declares each agent runtime's state directories (existing directories strictly under `$HOME`), and grant them automatically to Codex sessions related to that agent — a Bead labelled `agent-state:<agent>` or an explicit `--agent-state <agent>` launch option. Retire `NOGG_CODEX_EXTRA_WRITABLE_ROOTS`.
- Add a Codex sandbox diagnosis to `scripts/nogg doctor`, always reported as NOTE: offline Git-directory write probes by default, plus SSH fetch and `scripts/test` probes under `doctor --sandbox`.
- Ship and document a permission template for interactive Orchestration Agent sessions (worktree path patterns, deny list, auto-mode limitations).
- Map the already-delivered SPEC-u57h configuration to an approved task and requirement so it can be closed and mirrored normally.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `launch-profiles`: configured agent state roots; configured default profile/prompt recorded under the profile's own name.
- `codex-onboarding`: doctor sandbox diagnosis for Codex.
- `orchestration-agent`: documented permission template for interactive orchestrator sessions.

## Impact

Affects `scripts/nogg`, `scripts/session-launch`, `templates/nogging-config.json`, a new Claude permission template, tests and operational documentation (`docs/using-with-codex.md`, `docs/using-with-antigravity.md`, `docs/security-model.md`, `docs/running-work-in-sessions.md`). Estimated execution effort: 2–3 person-days.

No SSP/SCM/CSL/GSU/AGR task is changed. No execution work, release publication, user-global settings change, persistent service installation or human acceptance sign-off is authorized by this planning artifact.
