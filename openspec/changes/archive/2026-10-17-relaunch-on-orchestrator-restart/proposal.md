## Why

GitHub Issue #161 (`orchestrator restart adopts the live tmux session instead of relaunching Claude`) identified that `nogg orchestrator restart` only executes `systemctl --user restart nogg-orchestrator-<slug>.service`. Because the Claude Code process runs inside a tmux session hosted by the shared tmux server in its own cgroup/slice outside the systemd service unit, restarting the systemd service only terminates and restarts the Python supervisor (`scripts/nogg orchestrator run`).

When the new supervisor process starts, it checks `if tmux_has_session(name, "tmux"):`, sees the live tmux session, and adopts it (`"orchestrator: adopting the live session..."`). Consequently, the live Claude Code process is never restarted, and changes to the orchestrator launch prompt (`.nogging/launch-prompts/orchestrator.md`) or settings are never picked up. Currently, operators must manually kill the tmux session to achieve a real restart.

Adoption is intended when recovering from an unexpected supervisor process crash (`openspec/specs/orchestration-agent/spec.md:80-85`), but it contradicts the operator's intent during an explicit `orchestrator restart`. This change fixes `orchestrator restart` to cleanly end the live session so that the supervisor relaunches Claude under the current prompt and settings while preserving conversation continuity via `claude --resume <prior_session_id>`.

## What Changes

- **Clean session termination on restart:** `orchestrator restart` terminates the active orchestrator tmux session before restarting the supervisor service. The sequence stops the unit (`systemctl --user stop <unit>`), gracefully terminates the session pane (Ctrl+C, grace period up to `session_stop_grace_seconds`, fallback `kill-session`), marks the session record as `stopped` with exit reason `"restarted by operator"`, releases the orchestrator lock, and then starts the unit (`systemctl --user start <unit>`).
- **Shared termination helper:** The session termination and grace period logic in `orchestrator_stop()` is extracted into a shared helper function (`terminate_orchestrator_session()`) reused by both `stop` and `restart`.
- **Supervisor-only restart option:** An optional `--supervisor-only` flag on `orchestrator restart` allows restarting only the systemd unit without terminating the live tmux session, preserving the adoption behavior when only the supervisor process itself needs refreshing.
- **Specification and regression coverage:** The `orchestration-agent` specification gains scenarios for operator restart and supervisor-only restart. Fast, hermetic, stub-based regression tests are added in `scripts/orchestrator.test.sh` without requiring a real systemd daemon, Dolt, or tmux server.
- **Documentation:** `docs/operating-model.md` and `docs/running-work-in-sessions.md` document the restart behavior and `--supervisor-only`.

## Out of Scope

- **Rendered unit PATH finding:** Issue #161 noted a side finding regarding the minimal `PATH` (`%h/.local/bin:/usr/local/bin:/usr/bin:/bin`) in `templates/systemd/nogg-orchestrator.service.tmpl`, which does not include user environment managers like `~/.nvm` or `~/.pixi/bin`. Per planning instructions, this environment templating enhancement is excluded from this change and remains follow-up work.
- **Live orchestrator interruption:** No operation during planning or execution will interrupt or restart the running orchestrator session on this host.

## Non-Goals

- Changing the crash-recovery adoption behavior in `orchestrator run`: if the supervisor crashes while the tmux session is alive, the new supervisor continues to adopt the surviving session.
- Modifying session lifecycles for Lead or Planning sessions.
- Adding daemon reload dependencies or background polling daemons.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `orchestration-agent`: `orchestrator restart` terminates the live session and relaunches Claude with current prompt/settings and prior transcript, with optional `--supervisor-only` for unit-only restart.

## Impact

- Code: `scripts/nogg` (`orchestrator_restart`, `orchestrator_stop`, session termination helper, CLI arguments).
- Tests: `scripts/orchestrator.test.sh` (new regression cases using stubbed systemctl and tmux).
- Docs: `docs/operating-model.md`, `docs/running-work-in-sessions.md`.
- Host dependencies: none (uses existing systemctl, tmux backend, and standard library).
