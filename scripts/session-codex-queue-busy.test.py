#!/usr/bin/env python3
"""TASK-LCD-005: queue only after pane, backend and rollout all report idle."""
import json
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch

root, scratch = map(Path, sys.argv[1:3])
m = SourceFileLoader("queue_busy_nogg", str(root / "scripts/nogg")).load_module()
assert not m._is_legacy_mock(), "must run the real Codex queue delivery code"
reader = m.codex_delivery_module()
thread = "11111111-1111-1111-1111-111111111111"
cwd = str(scratch / "work")
rollout = scratch / "rollout.jsonl"
rollout.write_text(json.dumps({"type": "session_meta", "payload":
                              {"id": thread, "cwd": cwd}}) + "\n" +
                   json.dumps({"type": "event_msg", "payload": {"type": "task_started"}}) + "\n")
rec = {"name": "w", "agent": "codex", "working_dir": cwd, "codex_thread_id": thread}
timing = {"session_delivery_timeout_seconds": 0.3,
          "session_submit_verify_delay_seconds": 0.01,
          "session_submit_delay_seconds": 0.01}
calls = Path(__import__("os").environ["CODEX_QUEUE_CALLS"])
calls.unlink(missing_ok=True)

# A busy turn is visible in every channel. It must be refused without invoking
# the real queue subprocess, typing, or keying anything into the pane.
with patch.object(m, "resolve_codex_thread_id", return_value=thread), \
     patch.object(m, "_codex_rollout_path", return_value=rollout), \
     patch.object(m, "_delivery_composer_state", return_value="empty"), \
     patch.object(m, "session_pane_text", return_value="• Working (1s • esc to interrupt)\n› \n"), \
     patch.object(m, "_capture_backend_status", return_value="working"), \
     patch.object(m, "session_action") as action:
    try:
        m._codex_queue_deliver_locked("w", rec, "please do this", timing)
    except RuntimeError as exc:
        assert "Codex is busy" in str(exc), exc
    else:
        raise AssertionError("busy Codex queue unexpectedly succeeded")
    action.assert_not_called()
assert not calls.exists() or calls.read_text() == "", "codex queue ran while the session was busy"

# Even when the pane and backend look idle, a running exact-thread rollout is
# enough to prevent queueing.
with patch.object(m, "resolve_codex_thread_id", return_value=thread), \
     patch.object(m, "_codex_rollout_path", return_value=rollout), \
     patch.object(m, "_delivery_composer_state", return_value="empty"), \
     patch.object(m, "session_pane_text", return_value="› \n"), \
     patch.object(m, "_capture_backend_status", return_value="idle"), \
     patch.object(m, "session_action"):
    try:
        m._codex_queue_deliver_locked("w", rec, "please do this", timing)
    except RuntimeError as exc:
        assert "Codex is busy" in str(exc), exc
    else:
        raise AssertionError("running rollout unexpectedly allowed Codex queue")
assert not calls.exists() or calls.read_text() == "", "codex queue ran for a running rollout"

print("Codex busy queue gate: ok")
