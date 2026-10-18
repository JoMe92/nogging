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

print("Codex startup turn readiness: ok")
