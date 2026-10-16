#!/usr/bin/env bash
# Focused regression suite for TASK-RSI-002:
# Timing keys validation, bounded runtime readiness, and Antigravity Stop / fallback.
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
source "$here/lib/test-env.sh"

python3 - "$here" <<'PY'
import copy
import fcntl
import io
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import time
from types import SimpleNamespace
from unittest.mock import patch

sys.dont_write_bytecode = True
for key in list(os.environ):
    if key.startswith(('NOGG_', 'NOGGING_', 'HERDR_', 'TMUX')):
        os.environ.pop(key, None)

root = Path(sys.argv[1]).resolve().parent
from importlib.machinery import SourceFileLoader
m = SourceFileLoader('nogg_rsi_002', str(root / 'scripts/nogg')).load_module()

def refused(fn, exc_types=(RuntimeError, ValueError, TypeError)):
    try:
        fn()
    except exc_types:
        return
    raise AssertionError("expected function to be refused")

# ===========================================================================
# 1. Timing configuration validation on tmux and herdr
# ===========================================================================
# Defaults when keys are omitted
cfg = m.validate_session_timing_config({})
assert cfg["session_submit_delay_seconds"] == 0.3
assert cfg["session_submit_verify_delay_seconds"] == 0.5
assert cfg["session_delivery_timeout_seconds"] == 15.0
assert cfg["session_startup_timeout_seconds"] == 120.0

# Boundary values accepted
valid_cfg = {
    "session_submit_delay_seconds": 0,
    "session_submit_verify_delay_seconds": 0.001,
    "session_delivery_timeout_seconds": 1,
    "session_startup_timeout_seconds": 1,
}
cfg = m.validate_session_timing_config(valid_cfg)
assert cfg["session_submit_delay_seconds"] == 0.0
assert cfg["session_submit_verify_delay_seconds"] == 0.001

valid_cfg_max = {
    "session_submit_delay_seconds": 5,
    "session_submit_verify_delay_seconds": 5,
    "session_delivery_timeout_seconds": 120,
    "session_startup_timeout_seconds": 600,
}
cfg = m.validate_session_timing_config(valid_cfg_max)
assert cfg["session_submit_delay_seconds"] == 5.0
assert cfg["session_startup_timeout_seconds"] == 600.0

# Booleans refused (type bool is subclass of int in Python)
for key in ("session_submit_delay_seconds", "session_submit_verify_delay_seconds",
            "session_delivery_timeout_seconds", "session_startup_timeout_seconds"):
    refused(lambda k=key: m.validate_session_timing_config({k: True}))
    refused(lambda k=key: m.validate_session_timing_config({k: False}))
    refused(lambda k=key: m.validate_session_timing_config({k: "string"}))
    refused(lambda k=key: m.validate_session_timing_config({k: None}))
    refused(lambda k=key: m.validate_session_timing_config({k: [1]}))
    refused(lambda k=key: m.validate_session_timing_config({k: float("inf")}))
    refused(lambda k=key: m.validate_session_timing_config({k: float("nan")}))

# Range limits
# session_submit_delay_seconds: 0 through 5
refused(lambda: m.validate_session_timing_config({"session_submit_delay_seconds": -0.01}))
refused(lambda: m.validate_session_timing_config({"session_submit_delay_seconds": 5.01}))

# session_submit_verify_delay_seconds: greater than 0 through 5
refused(lambda: m.validate_session_timing_config({"session_submit_verify_delay_seconds": 0}))
refused(lambda: m.validate_session_timing_config({"session_submit_verify_delay_seconds": -1}))
refused(lambda: m.validate_session_timing_config({"session_submit_verify_delay_seconds": 5.01}))

# session_delivery_timeout_seconds: 1 through 120
refused(lambda: m.validate_session_timing_config({"session_delivery_timeout_seconds": 0}))
refused(lambda: m.validate_session_timing_config({"session_delivery_timeout_seconds": 0.99}))
refused(lambda: m.validate_session_timing_config({"session_delivery_timeout_seconds": 120.1}))

# session_startup_timeout_seconds: 1 through 600
refused(lambda: m.validate_session_timing_config({"session_startup_timeout_seconds": 0}))
refused(lambda: m.validate_session_timing_config({"session_startup_timeout_seconds": 0.99}))
refused(lambda: m.validate_session_timing_config({"session_startup_timeout_seconds": 600.1}))

print("ok 1 - timing configuration validation (ranges, types, booleans, non-finite values)")

# ===========================================================================
# 2. Setup mock session environment for testing readiness
# ===========================================================================
with tempfile.TemporaryDirectory() as tmp_dir:
    tmp = Path(tmp_dir)
    sessions_dir = tmp / "sessions"
    sessions_dir.mkdir(parents=True)
    m.CFG = {**m.CFG, "session_state_dir": str(sessions_dir), "session_stop_grace_seconds": 0}

    def make_session(name, agent="antigravity", backend="tmux", pid=1001, **extra):
        path = sessions_dir / f"{name}.json"
        rec = {
            "name": name,
            "agent": agent,
            "backend": backend,
            "backend_ref": {"label": name, "session_pid": pid} if backend == "herdr" else {"name": name},
            "working_dir": str(tmp / "worktree"),
            "role": "lead",
            "bead_id": "SPEC-35h7",
            "state": "running",
            "started_at": "2026-10-16T12:00:00",
            "session_pid": pid,
            "session_pid_start": f"start_{pid}",
            "session_pid_ns": "ns_1",
            "antigravity_initial_turn": True,
            "antigravity_conversation_id": None,
            **extra
        }
        m.write_session(path, rec)
        return path, rec

    # Fake clock helper
    class Clock:
        def __init__(self, start=100.0):
            self.current = start
        def now(self):
            return self.current
        def sleep(self, seconds):
            self.current += seconds

    # ===========================================================================
    # 2a. >30-second readiness for Antigravity
    # ===========================================================================
    name = "sf-lead-slow"
    path, rec = make_session(name)
    clock = Clock(start=1000.0)
    stop_event_payload = {
        "conversationId": "00000000-0000-4000-8000-000000000001",
        "fullyIdle": True,
        "executionNum": 1,
        "workspacePaths": [str(Path(rec["working_dir"]).resolve())]
    }

    # At t=35s after start (t=1035), the Stop event fires
    def slow_sleep(duration):
        clock.sleep(duration)
        if clock.current >= 1035.0:
            rec_on_disk = json.loads(path.read_text())
            rec_on_disk["antigravity_ready_at"] = "2026-10-16T12:00:35"
            m.write_session(path, rec_on_disk)

    with patch.object(m, "tmux_sessions", return_value={name}), \
         patch.object(m, "session_action", side_effect=lambda s, op, *a, **k: 1001 if op == "pid" else None), \
         patch.object(m, "process_start", return_value="start_1001"), \
         patch.object(m.time, "monotonic", side_effect=clock.now), \
         patch.object(m.time, "sleep", side_effect=slow_sleep):
        # Should succeed even though it exceeded 30s
        m.await_session_input_ready(name, timeout=120)
        updated = json.loads(path.read_text())
        assert updated.get("readiness_source") == "stop_event"
        assert updated.get("readiness_at")

    print("ok 2 - >30-second readiness wait succeeds when Stop event arrives at 35s")

    # ===========================================================================
    # 2b. Missing Stop with reliable fallback (herdr backend)
    # ===========================================================================
    name = "sf-lead-fallback"
    path, rec = make_session(name, backend="herdr", pid=2001, session_pid_start="start_2001")
    clock = Clock(start=2000.0)

    # Empty composer framed by rules
    agy_empty_pane = "\n".join([
        "────────────────────────",
        "> ",
        "────────────────────────",
        "? for shortcuts"
    ])

    herdr_mock = SimpleNamespace(
        capabilities=SimpleNamespace(capture_attributes=True, agent_status=True),
        _pane=lambda ref: {"pane_id": "p1"},
        _identity=lambda ref, pane: True
    )

    def herdr_action(sess, op, *a, **kw):
        if op == "pid":
            return 2001
        if op == "agent_status":
            return "idle"
        if op == "capture":
            return agy_empty_pane
        return None

    with patch.object(m, "tmux_sessions", return_value={name}), \
         patch.object(m, "session_backend", return_value=herdr_mock), \
         patch.object(m, "backend_for_name", return_value=(herdr_mock, {"pane_id": "p1"})), \
         patch.object(m, "session_action", side_effect=herdr_action), \
         patch.object(m, "process_start", return_value="start_2001"), \
         patch.object(m.time, "monotonic", side_effect=clock.now), \
         patch.object(m.time, "sleep", side_effect=clock.sleep):
        # Two consecutive samples of idle + empty composer on herdr suffice
        m.await_session_input_ready(name, timeout=15)
        updated = json.loads(path.read_text())
        assert updated.get("readiness_source") == "backend_status"
        assert updated.get("readiness_at")
        assert updated.get("antigravity_conversation_id") is None  # Never fabricated

    print("ok 3 - missing Stop event resolves via two consecutive idle backend samples on herdr")

    # ===========================================================================
    # 2c. Missing Stop without reliable fallback (tmux backend)
    # ===========================================================================
    name = "sf-lead-no-fallback"
    path, rec = make_session(name, backend="tmux", pid=3001, session_pid_start="start_3001")
    clock = Clock(start=3000.0)

    # On tmux, agent_status returns None, and Stop event is absent -> times out
    with patch.object(m, "tmux_sessions", return_value={name}), \
         patch.object(m, "session_action", side_effect=lambda s, op, *a, **k: 3001 if op == "pid" else None), \
         patch.object(m, "process_start", return_value="start_3001"), \
         patch.object(m.time, "monotonic", side_effect=clock.now), \
         patch.object(m.time, "sleep", side_effect=clock.sleep):
        try:
            m.await_session_input_ready(name, timeout=10)
        except RuntimeError as exc:
            msg = str(exc)
            assert "startup readiness timed out" in msg
            assert "Stop event" in msg
            assert "session log" in msg
            assert "session watch" in msg
            assert "hook diagnostics" in msg
        else:
            raise AssertionError("expected readiness timeout without Stop event or fallback")

    print("ok 4 - missing Stop without fallback times out with diagnostic pointing to log, watch, hook")

    # ===========================================================================
    # 2d. Stale Stop event predating launch
    # ===========================================================================
    name = "sf-lead-stale"
    path, rec = make_session(name, started_at="2026-10-16T14:00:00",
                             antigravity_ready_at="2026-10-16T13:59:00", pid=4001)
    clock = Clock(start=4000.0)

    with patch.object(m, "tmux_sessions", return_value={name}), \
         patch.object(m, "session_action", side_effect=lambda s, op, *a, **k: 4001 if op == "pid" else None), \
         patch.object(m, "process_start", return_value="start_4001"), \
         patch.object(m.time, "monotonic", side_effect=clock.now), \
         patch.object(m.time, "sleep", side_effect=clock.sleep):
        try:
            m.await_session_input_ready(name, timeout=5)
        except RuntimeError as exc:
            assert "stale Stop event" in str(exc)
        else:
            raise AssertionError("stale Stop event was incorrectly accepted as readiness")

    print("ok 5 - stale Stop event predating launch is ignored")

    # ===========================================================================
    # 2e. Process disappearance
    # ===========================================================================
    name = "sf-lead-disappear"
    path, rec = make_session(name, pid=5001, session_pid_start="start_5001")
    clock = Clock(start=5000.0)

    # Process disappears on poll: pid returns None or different PID
    with patch.object(m, "tmux_sessions", return_value={name}), \
         patch.object(m, "session_action", side_effect=lambda s, op, *a, **k: 9999 if op == "pid" else None), \
         patch.object(m, "process_start", return_value="start_9999"), \
         patch.object(m.time, "monotonic", side_effect=clock.now), \
         patch.object(m.time, "sleep", side_effect=clock.sleep):
        try:
            m.await_session_input_ready(name, timeout=60)
        except RuntimeError as exc:
            assert "process disappeared or changed" in str(exc)
            assert clock.current < 5005.0  # Refuses immediately, did not wait for 60s
        else:
            raise AssertionError("process disappearance did not fail immediately")

    print("ok 6 - process disappearance fails immediately without waiting for deadline")

    # ===========================================================================
    # 2f. Dialogs block readiness
    # ===========================================================================
    name = "sf-lead-dialog"
    path, rec = make_session(name, pid=6001, session_pid_start="start_6001",
                             antigravity_ready_at="2026-10-16T12:05:00")
    clock = Clock(start=6000.0)

    # Pane shows permission dialog
    agy_dialog_pane = "\n".join([
        "────────────────────────",
        "> ",
        "────────────────────────",
        "Do you trust the contents of this project?",
        "❯ 1. Yes"
    ])

    with patch.object(m, "tmux_sessions", return_value={name}), \
         patch.object(m, "session_pane_text", return_value=agy_dialog_pane), \
         patch.object(m, "session_action", side_effect=lambda s, op, *a, **k: 6001 if op == "pid" else None), \
         patch.object(m, "process_start", return_value="start_6001"), \
         patch.object(m.time, "monotonic", side_effect=clock.now), \
         patch.object(m.time, "sleep", side_effect=clock.sleep):
        try:
            m.await_session_input_ready(name, timeout=5)
        except RuntimeError as exc:
            assert "pane=needs_input" in str(exc) or "contrary state" in str(exc)
        else:
            raise AssertionError("readiness was granted during trust/permission dialog")

    print("ok 7 - permission/trust dialog blocks readiness and does not send speculative input")

    # ===========================================================================
    # 2g. Claude readiness (idle prompt box vs needs_input)
    # ===========================================================================
    name = "sf-claude-ready"
    path, rec = make_session(name, agent="claude", pid=7001)
    clock = Clock(start=7000.0)

    claude_idle_pane = "prior output\n────────────────────\n❯ \n────────────────────\n"
    with patch.object(m, "tmux_sessions", return_value={name}), \
         patch.object(m, "session_pane_text", return_value=claude_idle_pane), \
         patch.object(m, "session_action", side_effect=lambda s, op, *a, **k: 7001 if op == "pid" else None), \
         patch.object(m, "process_start", return_value="start_7001"), \
         patch.object(m.time, "monotonic", side_effect=clock.now), \
         patch.object(m.time, "sleep", side_effect=clock.sleep):
        m.await_session_input_ready(name, timeout=10)
        assert json.loads(path.read_text()).get("readiness_source") == "pane"

    # Claude with permission dialog fails
    claude_dialog_pane = "Do you want to proceed?\n❯ 1. Yes\n"
    with patch.object(m, "tmux_sessions", return_value={name}), \
         patch.object(m, "session_pane_text", return_value=claude_dialog_pane), \
         patch.object(m, "session_action", side_effect=lambda s, op, *a, **k: 7001 if op == "pid" else None), \
         patch.object(m, "process_start", return_value="start_7001"), \
         patch.object(m.time, "monotonic", side_effect=clock.now), \
         patch.object(m.time, "sleep", side_effect=clock.sleep):
        refused(lambda: m.await_session_input_ready(name, timeout=2))

    print("ok 8 - Claude readiness requires empty composer and idle state, refusing dialogs")

    # ===========================================================================
    # 2h. Codex readiness (ready composer before kickoff)
    # ===========================================================================
    name = "sf-codex-ready"
    path, rec = make_session(name, agent="codex", pid=8001)
    clock = Clock(start=8000.0)

    codex_idle_pane = "› \x1b[2mAsk Codex to do anything\x1b[0m\n"
    with patch.object(m, "tmux_sessions", return_value={name}), \
         patch.object(m, "session_pane_text", return_value=codex_idle_pane), \
         patch.object(m, "session_action", side_effect=lambda s, op, *a, **k: 8001 if op == "pid" else None), \
         patch.object(m, "process_start", return_value="start_8001"), \
         patch.object(m.time, "monotonic", side_effect=clock.now), \
         patch.object(m.time, "sleep", side_effect=clock.sleep):
        m.await_session_input_ready(name, timeout=10, for_kickoff=True)
        assert json.loads(path.read_text()).get("readiness_source") == "pane"

    # Codex with unsubmitted pasted content is not ready
    codex_pasted_pane = "[Pasted Content]\n› \x1b[2mAsk Codex to do anything\x1b[0m\n"
    with patch.object(m, "tmux_sessions", return_value={name}), \
         patch.object(m, "session_pane_text", return_value=codex_pasted_pane), \
         patch.object(m, "session_action", side_effect=lambda s, op, *a, **k: 8001 if op == "pid" else None), \
         patch.object(m, "process_start", return_value="start_8001"), \
         patch.object(m.time, "monotonic", side_effect=clock.now), \
         patch.object(m.time, "sleep", side_effect=clock.sleep):
        refused(lambda: m.await_session_input_ready(name, timeout=2, for_kickoff=True))

    print("ok 9 - Codex readiness requires ready composer, refusing pending input")

print("All session-input-ready checks passed.")
PY
