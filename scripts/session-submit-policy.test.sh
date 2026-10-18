#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$root/scripts/nogg" <<'PY'
import io, sys, tempfile, threading
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("session_submit_policy", sys.argv[1]).load_module()
RULE = "────────────────────"
def pane(text="", *, dim=False):
    prefix = "\x1b[2m" if dim else ""
    suffix = "\x1b[0m" if dim else ""
    return f"{RULE}\n❯ {prefix}{text}{suffix}\n{RULE}\n"
class Clock:
    now = 0.0
    def monotonic(self): return self.now
    def sleep(self, seconds): self.now += seconds

def fixture(initial=None, *, outcome="accepted", delay_render=0, baseline="idle"):
    clock = Clock()
    state = {"pane": initial if initial is not None else pane(), "status": baseline,
             "actions": [], "outcome": outcome, "enters": 0, "captures": 0,
             "delay_render": delay_render, "text": None, "render_pending": False}
    temp = tempfile.TemporaryDirectory()
    root = Path(temp.name)
    rec = {"name": "s", "agent": "claude", "role": "lead", "working_dir": str(root)}
    backend = SimpleNamespace(capabilities=SimpleNamespace(capture_attributes=True))
    def action(name, op, *args, **kwargs):
        state["actions"].append((op, args))
        if op == "capture":
            state["captures"] += 1
            if state["render_pending"] and state["captures"] >= state["delay_render"]:
                state["pane"] = pane(state["text"])
                state["render_pending"] = False
            return state["pane"]
        if op == "agent_status": return state["status"]
        if op == "send_text":
            state["text"] = args[0]
            state["render_pending"] = bool(state["delay_render"])
            if not state["delay_render"]: state["pane"] = pane(args[0])
            return None
        if op == "send_keys":
            key = args[0]
            if key == "enter":
                state["enters"] += 1
                if state["outcome"] == "accepted" or (state["outcome"] == "swallow_once" and state["enters"] == 2):
                    state["pane"] = pane()
                    state["status"] = "working"
                elif state["outcome"] == "unrelated":
                    state["pane"] = pane("different instruction")
                elif state["outcome"] == "unknown":
                    state["pane"] = "unframed text"
            elif key == "ctrl+u": state["pane"] = pane()
            elif key == "backspace": state["pane"] = pane()
            return None
        raise AssertionError((op, args))
    timing = {"session_submit_delay_seconds": .3,
              "session_submit_verify_delay_seconds": .5,
              "session_delivery_timeout_seconds": 2.,
              "session_startup_timeout_seconds": 4.}
    patches = [
        patch.object(m, "load_session", return_value=(root / "s.json", rec)),
        patch.object(m, "tmux_has_session", return_value=True),
        patch.object(m, "tmux_sessions", return_value={"s"}),
        patch.object(m, "reconciled_state", return_value="running"),
        patch.object(m, "backend_for_name", return_value=(backend, {})),
        patch.object(m, "session_action", side_effect=action),
        patch.object(m, "sessions_dir", return_value=root),
        patch.object(m, "validate_session_timing_config", return_value=timing),
        patch.object(m.time, "monotonic", clock.monotonic),
        patch.object(m.time, "sleep", clock.sleep),
    ]
    return temp, state, clock, patches

def run_send(initial=None, **kwargs):
    temp, state, clock, patches = fixture(initial, **kwargs)
    try:
        with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], patches[8], patches[9], io.StringIO() as out, patch("sys.stdout", out):
            try: m.session_send("s", "send this\nwith two lines")
            except Exception as exc: raise AssertionError((exc, state, clock.now)) from exc
            return state, clock
    finally: temp.cleanup()

state, clock = run_send()
assert state["enters"] == 1, state
assert clock.now >= .3, clock.now
assert [a for a in state["actions"] if a[0] == "send_text"] == [("send_text", ("send this\nwith two lines",))]
state, _ = run_send(outcome="swallow_once")
assert state["enters"] == 2, state
state, _ = run_send(delay_render=3)
first_enter = next(i for i, (op, _) in enumerate(state["actions"]) if op == "send_keys")
assert any(op == "capture" for op, _ in state["actions"][:first_enter]), state
for bad in (pane("unrelated prior text"), "unframed text"):
    temp, state, _clock, patches = fixture(bad)
    try:
        with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], patches[8], patches[9]:
            try: m.session_send("s", "new")
            except RuntimeError as exc: assert "nothing was typed or submitted" in str(exc), exc
            else: raise AssertionError("unsafe composer accepted")
            assert not any(op in ("send_text", "send_keys") for op, _ in state["actions"]), state
    finally: temp.cleanup()
for outcome, phrase, max_enters in (("unrelated", "composer is other", 1), ("unknown", "composer is unknown", 1)):
    temp, state, _clock, patches = fixture(outcome=outcome)
    try:
        with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], patches[8], patches[9]:
            try: m.session_send("s", "new")
            except RuntimeError as exc: assert phrase in str(exc), (outcome, exc, state)
            else: raise AssertionError("unverified send accepted")
            assert state["enters"] == max_enters, state
    finally: temp.cleanup()
print("session submit policy: safe preflight, delayed paste, one Enter, owned retry and unknown refusal passed")
PY
