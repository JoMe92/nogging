## Context

GitHub Issue #161 identified that `nogg orchestrator restart` only executes `systemctl --user restart nogg-orchestrator-<slug>.service`. In `scripts/nogg`:

- `orchestrator_restart()` (~line 5792 on `develop`) calls `_systemctl("restart", unit)`.
- The tmux server process running the Claude session lives outside the systemd service unit's cgroup. Thus, restarting the systemd service unit terminates only the Python supervisor (`scripts/nogg orchestrator run`), leaving the tmux pane running Claude completely untouched.
- When systemd starts the new supervisor process, `orchestrator_run()` executes `if tmux_has_session(name, "tmux"):`. Because the tmux session was never terminated, it takes the adoption branch (`"orchestrator: adopting the live session..."`), reconnects logging, and does not relaunch Claude.
- `session_launch("orchestrator", ..., prompt="orchestrator", resume=prior_session_id)` is only called in the `else` (no-session) branch. Therefore, prompt updates (`.nogging/launch-prompts/orchestrator.md`) and settings are never reloaded during `nogg orchestrator restart`.
- In contrast, `orchestrator_stop()` (~line 5770 on `develop`) already implements graceful session termination: it stops and disables the unit, sends Ctrl+C to the tmux session, waits up to `session_stop_grace_seconds`, falls back to `kill-session`, transitions the session record to `stopped`, and releases the orchestrator lock.

## Goals / Non-Goals

**Goals:**

- `nogg orchestrator restart` terminates the live orchestrator tmux session gracefully before restarting the service, so the new supervisor launches Claude afresh with the updated prompt and settings while resuming the conversation transcript.
- Extract common session termination logic into a clean helper shared between `orchestrator_stop` and `orchestrator_restart`.
- Provide an explicit `--supervisor-only` flag on `orchestrator restart` to retain unit-only restart when desired.
- Verify behavior with deterministic, fast stub-based tests in `scripts/orchestrator.test.sh` that require no real tmux server, no systemd daemon, no Dolt/bd, and no PID assumptions.
- Document the restart behavior in operator guides.

**Non-Goals:**

- Modifying the minimal PATH template in `templates/systemd/nogg-orchestrator.service.tmpl` (out of scope per Issue #161 side finding).
- Altering the crash recovery adoption path in `orchestrator_run` (an unexpected crash of the supervisor must still adopt a surviving tmux session).
- Modifying session management for Lead or Planning roles.

## Decisions

### Decision 1: Restart sequence (stop unit -> terminate session -> start unit)

To avoid race conditions where systemd's `Restart=always` could immediately restart the supervisor while the old session is being killed, `orchestrator_restart()` executes the following sequence:

1. `_systemctl("stop", unit)`: Stop the systemd supervisor service cleanly.
2. Terminate the active tmux session via the shared termination helper (sending Ctrl+C, waiting up to `session_stop_grace_seconds`, falling back to `kill`), update the session record to `stopped` with `exit_reason="restarted by operator"`, and release the orchestrator lock if held.
3. `_systemctl("start", unit)`: Start the systemd supervisor service.

When the new supervisor process starts via `orchestrator run`, it checks `tmux_has_session(name, "tmux")`. Since the session was terminated, it executes the no-session branch, reads `prior_session_id` from the existing session record, and calls `session_launch(..., prompt="orchestrator", resume=prior_session_id)`. Claude starts with the latest prompt file and configuration while maintaining transcript history via `--resume`.

### Decision 2: Factoring out `terminate_orchestrator_session(exit_reason)`

`orchestrator_stop()` currently embeds tmux lookup, key sending, grace waiting, session killing, record state transition, and lock release. This logic is extracted into a helper:

```python
def terminate_orchestrator_session(exit_reason="stopped by operator"):
    name = orchestrator_session_name()
    rec_path = orchestrator_sessions_dir() / f"{name}.json"
    rec = json.loads(rec_path.read_text()) if rec_path.exists() else None
    substrate = session_backend("tmux")
    ref = record_backend_ref(rec) if rec else name
    if substrate.exists(ref):
        substrate.send_keys(ref, "ctrl+c", check=False)
        deadline = time.monotonic() + float(scfg("session_stop_grace_seconds", 10))
        while time.monotonic() < deadline and substrate.exists(ref):
            time.sleep(0.2)
        if substrate.exists(ref):
            substrate.kill(ref)
    if rec_path.exists():
        rec = json.loads(rec_path.read_text())
        if rec.get("state") in SESSION_ACTIVE_STATES:
            transition(rec_path, rec, "stopped", exit_reason=exit_reason)
    release_orchestrator_lock()
```

Both `orchestrator_stop()` and `orchestrator_restart()` call this helper, ensuring uniform timeout handling, state transitions, and lock cleanup.

### Decision 3: CLI option `--supervisor-only`

The CLI parser for `orchestrator restart` adds an optional flag:

```python
ores = orcsub.add_parser("restart")
ores.add_argument("--supervisor-only", action="store_true",
                  help="restart only the systemd supervisor without terminating the tmux session")
```

When `--supervisor-only` is passed, `orchestrator_restart(supervisor_only=True)` calls only `_systemctl("restart", unit)`, reproducing the prior unit-only restart behavior.

### Decision 4: Deterministic stub-based regression testing

In `scripts/orchestrator.test.sh`, tests run in a fixture directory with PATH-injected stubs for `systemctl`, `tmux`, `claude`, and `bd`.

- `systemctl` stub tracks calls to `stop`, `start`, and `restart`.
- `tmux` stub manages mock session markers (`sess-<name>`).
- New test cases verify:
  1. Standard `orchestrator restart`: verifies `stop` is called on systemctl, the session marker is removed (terminated), `start` is called on systemctl, and the session record reflects `exit_reason="restarted by operator"`.
  2. `orchestrator restart --supervisor-only`: verifies `restart` is called on systemctl without removing the session marker.

All tests run without root, without Dolt/bd, without unshare, and execute in under 2 seconds.

### Decision 5: Documentation updates

Update `docs/operating-model.md` and `docs/running-work-in-sessions.md` to document:
- `scripts/nogg orchestrator restart` cleanly relaunches the Claude Code session with the current prompt and settings while keeping conversation continuity.
- `scripts/nogg orchestrator restart --supervisor-only` restarts only the supervisor service.

## Dependencies and Parallel Lanes

Branch naming convention: `<type>/relaunch-on-orchestrator-restart`

- Lane 1 (`refactor/`): TASK-ORR-001 (Helper extraction)
- Lane 2 (`fix/`): TASK-ORR-002 (Restart implementation & CLI flag)
- Lane 3 (`test/`): TASK-ORR-003 (Regression tests in `scripts/orchestrator.test.sh`)
- Lane 4 (`docs/`): TASK-ORR-004 (Documentation updates)

Dependency graph:
- TASK-ORR-001 has no prerequisites.
- TASK-ORR-002 depends on TASK-ORR-001.
- TASK-ORR-003 and TASK-ORR-004 depend on TASK-ORR-002 and can proceed in parallel once TASK-ORR-002 is merged.

## Risks and Mitigations

- **Risk:** Systemd restart race if unit is not stopped first.
  - **Mitigation:** Explicit `_systemctl("stop", unit)` precedes session termination; `_systemctl("start", unit)` only runs after the session is confirmed dead.
- **Risk:** Claude session takes long to exit on SIGINT/Ctrl+C.
  - **Mitigation:** Bounded grace period up to `session_stop_grace_seconds` (default 10s) with fallback to `kill-session`.
- **Risk:** Interruption of live orchestrator on development/host machine.
  - **Mitigation:** All tests use isolated fixture checkouts and mock binaries; no command interacts with the host's live `nogg-orchestrator-nogging` service or PID 926.
