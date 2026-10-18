#!/usr/bin/env python3
"""TASK-LCD-004: startup turns gate Codex readiness and pane Enter."""
import json
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest.mock import patch

root, scratch = map(Path, sys.argv[1:3])
m = SourceFileLoader("startup_turn_nogg", str(root / "scripts/nogg")).load_module()
assert not m._is_legacy_mock(), "must run the real readiness and delivery code"
reader = m.codex_delivery_module()

def event(kind):
    return json.dumps({"type": "event_msg", "payload": {"type": kind}}) + "\n"

rollout = scratch / "rollout.jsonl"
rollout.write_text(event("task_started") + event("unknown_future_event"))
assert reader.turn_state(rollout) == "running"
with rollout.open("a") as stream:
    stream.write(event("task_complete"))
assert reader.turn_state(rollout) == "idle"
with rollout.open("a") as stream:
    stream.write(event("task_started"))
assert reader.turn_state(rollout) == "running"
assert reader.turn_state(scratch / "missing.jsonl") == "none"

# A stable empty composer is not ready while this launch's startup turn is absent.
rec = {"name": "codex-startup", "agent": "codex", "codex_startup_prompt": True,
       "working_dir": str(scratch), "codex_thread_id": "thread-1"}
memory = {"now": 0.0, "rc_grace": 1.0}
with patch.object(m, "session_pane_text", return_value="› \n"), \
     patch.object(m, "_capture_backend_status", return_value="idle"), \
     patch.object(m, "_ready_composer_kind", return_value="empty"), \
     patch.object(m, "resolve_codex_thread_id", return_value="thread-1"), \
     patch.object(m, "_codex_rollout_path", return_value=rollout), \
     patch.object(reader, "turn_state", return_value="none"):
    state = m._readiness_observation("codex-startup", rec, "codex", True, memory)
assert state[0] == "wait" and "no completed startup turn" in state[1], state

# No startup prompt (resume or promptless) preserves the old steady-composer rule.
resume_rec = dict(rec, codex_startup_prompt=False)
with patch.object(m, "session_pane_text", return_value="› \n"), \
     patch.object(m, "_capture_backend_status", return_value="idle"), \
     patch.object(m, "_ready_composer_kind", return_value="empty"):
    state = m._readiness_observation("codex-startup", resume_rec, "codex", True, memory)
assert state[0] == "candidate", state

# The real pane submit path waits when the Codex turn is running and proceeds
# after the exact thread reaches a terminal event.
rec_path = scratch / "session.json"
rec_path.write_text(json.dumps(rec))
clock = {"now": 0.0}
def sleep(seconds):
    clock["now"] += seconds
def pane():
    return "• Working (0s • esc to interrupt)\n\n› hello\n" if clock["now"] < 0.2 else "› hello\n"
with patch.object(m, "session_pane_text", side_effect=lambda *_: pane()), \
     patch.object(m, "load_session", return_value=(rec_path, rec)), \
     patch.object(m, "resolve_codex_thread_id", return_value="thread-1"), \
     patch.object(m, "_codex_rollout_path", return_value=rollout), \
     patch.object(reader, "turn_state", side_effect=lambda _path: "running" if clock["now"] < 0.2 else "idle"), \
     patch.object(m.time, "monotonic", side_effect=lambda: clock["now"]), \
     patch.object(m.time, "sleep", side_effect=sleep):
    m._wait_for_codex_turn_before_enter("codex-startup", 1.0,
        {"session_submit_verify_delay_seconds": 0.1})
assert clock["now"] >= 0.2, clock

order = []
with patch.object(m, "_capture_backend_status", return_value="idle"), \
     patch.object(m, "_delivery_composer_state", side_effect=["empty", "pending", "pending"]), \
     patch.object(m, "_wait_for_owned_composer"), \
     patch.object(m, "_wait_for_codex_turn_before_enter", side_effect=lambda *_: order.append("idle")), \
     patch.object(m, "_submission_observation", return_value="submitted"), \
     patch.object(m, "session_action", side_effect=lambda _name, action, *_: order.append(action)), \
     patch.object(m.time, "monotonic", return_value=0.0), \
     patch.object(m.time, "sleep"):
    m._deliver_pane_locked("codex-startup", "codex", "hello",
        timing={"session_delivery_timeout_seconds": 2.0,
                "session_submit_delay_seconds": 0.1,
                "session_submit_verify_delay_seconds": 0.1})
assert order.index("idle") < order.index("send_keys"), order

# A changed working status alone cannot prove that Codex submitted pending text.
with patch.object(m, "session_action", return_value="working"), \
     patch.object(m, "_delivery_composer_state", return_value="pending"):
    assert m._submission_observation("codex-startup", "codex", "hello", "idle", True) == "pending"

print("Codex startup turn readiness and turn-gated submit: ok")
