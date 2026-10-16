#!/usr/bin/env bash
# TASK-HSS-005: session nudge --message clears pending input row-by-row and verifies exact submission (Decision 6, N2).
set -euo pipefail
for name in $(compgen -e); do
  case "$name" in NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_TMPDIR) unset "$name" ;; esac
done
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import contextlib
import io
import pathlib
import re
import sys
import tempfile
from importlib.machinery import SourceFileLoader
from types import SimpleNamespace
from unittest.mock import patch

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts/lib"))
import session_backend
import session_backend_tmux
import session_backend_herdr

# Decision 6: backspace joins the backend key set; tmux sends BSpace, herdr sends backspace
assert "backspace" in session_backend.KEYS
assert session_backend_tmux.TmuxBackend._KEYS["backspace"] == "BSpace"

# Short socket path assertion under /tmp (< 108 bytes)
with tempfile.TemporaryDirectory(prefix="nogg.", dir="/tmp") as tmpdir:
    sock_path = pathlib.Path(tmpdir) / "test.sock"
    assert len(str(sock_path).encode("utf-8")) < 108

# Verify TmuxBackend and HerdrBackend send_keys key translations
tmux_calls = []
def fake_tmux_run(*args, **kw):
    tmux_calls.append(args)
    return SimpleNamespace(returncode=0, stdout="")

tmux_backend = session_backend_tmux.TmuxBackend({"session_tmux_socket": "test_sock"}, fake_tmux_run)
tmux_backend.send_keys("test_session", "backspace")
assert ("send-keys", "-t", "test_session", "BSpace") in [c[3:] for c in tmux_calls]

herdr_calls = []
def fake_herdr_run(*args, **kw):
    herdr_calls.append(args)
    return SimpleNamespace(returncode=0, stdout="")

herdr_backend = session_backend_herdr.HerdrBackend({"session_herdr_session": "test_herdr"}, fake_herdr_run)
with patch.object(herdr_backend, "_target", return_value="p1"):
    herdr_backend.send_keys("test_ref", "backspace")
assert any(c[3:] == ("pane", "send-keys", "p1", "backspace") for c in herdr_calls)

# Load scripts/nogg as nudge_clear
m = SourceFileLoader("nudge_clear", str(root / "scripts/nogg")).load_module()

# Load fixtures
fixtures_dir = root / "scripts/fixtures/claude-panes"
empty_fix = (fixtures_dir / "empty.txt").read_text()
placeholder_fix = (fixtures_dir / "placeholder.txt").read_text()
two_row_fix = (fixtures_dir / "two-row-wrapped.txt").read_text()
one_row_fix = (fixtures_dir / "ctrl-u-cleared-one-row.txt").read_text()
merged_fix = (fixtures_dir / "merged-stale-input.txt").read_text()

# Verify classification of the derived fixtures
assert m._claude_prompt_input(two_row_fix)[0] == "input"
assert "\n" in m._claude_prompt_input(two_row_fix)[1]
assert m._claude_prompt_input(one_row_fix)[0] == "input"
assert len(m._claude_prompt_input(one_row_fix)[1]) < len(m._claude_prompt_input(two_row_fix)[1])
assert m._claude_prompt_input(merged_fix)[0] == "input"
assert "wrapsexplicit" in m._claude_prompt_input(merged_fix)[1]

class StatefulSubstrate:
    def __init__(self, backend_name="tmux"):
        self.name = backend_name
        self.capabilities = SimpleNamespace(capture_attributes=True, agent_status=True)
        self.pane = empty_fix
        self.actions = []
        self.text_typed = []
        self.enters_sent = 0
        self.ctrl_u_sent = 0
        self.backspace_sent = 0
        self.custom_handler = None

    def capture(self, ref, attributes=False):
        self.actions.append(("capture", attributes))
        return self.pane

    def send_keys(self, ref, key, check=True):
        self.actions.append(("send_keys", key))
        if key == "ctrl+u":
            self.ctrl_u_sent += 1
        elif key == "backspace":
            self.backspace_sent += 1
        elif key == "enter":
            self.enters_sent += 1

        if self.custom_handler:
            self.custom_handler(self, "send_keys", key)

    def send_text(self, ref, text):
        self.actions.append(("send_text", text))
        self.text_typed.append(text)
        if self.custom_handler:
            self.custom_handler(self, "send_text", text)

    def agent_status(self, ref):
        self.actions.append(("agent_status",))
        return "idle"

# Test all scenarios on both backends
for backend in ("tmux", "herdr"):
    R = '─' * 30

    # 1. Wrapped input cleared by repeated ctrl+u, then exact message typed and submitted
    sub = StatefulSubstrate(backend_name=backend)
    sub.pane = two_row_fix
    def handler_1(s, action, val):
        if action == "send_keys" and val == "ctrl+u":
            if s.pane == two_row_fix:
                s.pane = one_row_fix
            elif s.pane == one_row_fix:
                s.pane = empty_fix
        elif action == "send_text":
            s.pane = f"{R}\n❯ {val}\n{R}\n"
        elif action == "send_keys" and val == "enter":
            s.pane = empty_fix

    sub.custom_handler = handler_1
    rec = {"name": f"s1_{backend}", "agent": "claude"}
    buf = io.StringIO()
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         patch.object(m.time, "sleep"), \
         contextlib.redirect_stdout(buf):
        m.session_nudge(rec["name"], "continue with the next task")

    assert f"nudged {rec['name']}" in buf.getvalue()
    assert sub.ctrl_u_sent == 2, f"{backend}: expected 2 ctrl+u, got {sub.ctrl_u_sent}"
    assert sub.backspace_sent == 0
    assert sub.text_typed == ["continue with the next task"]
    assert sub.enters_sent >= 1

    # 2. No progress with ctrl+u, then backspace fallback clears
    sub = StatefulSubstrate(backend_name=backend)
    sub.pane = f"{R}\n❯ hello\n{R}\n"
    def handler_2(s, action, val):
        if action == "send_keys" and val == "ctrl+u":
            pass  # Does not shorten
        elif action == "send_keys" and val == "backspace":
            if s.backspace_sent >= 6:
                s.pane = empty_fix
        elif action == "send_text":
            s.pane = f"{R}\n❯ {val}\n{R}\n"
        elif action == "send_keys" and val == "enter":
            s.pane = empty_fix

    sub.custom_handler = handler_2
    rec = {"name": f"s2_{backend}", "agent": "claude"}
    buf = io.StringIO()
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         patch.object(m.time, "sleep"), \
         contextlib.redirect_stdout(buf):
        m.session_nudge(rec["name"], "my new message")

    assert f"nudged {rec['name']}" in buf.getvalue()
    assert sub.ctrl_u_sent == 1, f"{backend}: expected 1 ctrl+u, got {sub.ctrl_u_sent}"
    assert sub.backspace_sent == 6, f"{backend}: expected 6 backspaces, got {sub.backspace_sent}"
    assert sub.text_typed == ["my new message"]
    assert sub.enters_sent >= 1

    # 3. A composer that never clears: nudge fails, no text typed, no Enter
    sub = StatefulSubstrate(backend_name=backend)
    sub.pane = f"{R}\n❯ stuck input\n{R}\n"
    rec = {"name": f"s3_{backend}", "agent": "claude"}
    buf = io.StringIO()
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         patch.object(m.time, "sleep"), \
         contextlib.redirect_stdout(buf):
        try:
            m.session_nudge(rec["name"], "should not be typed")
            raise AssertionError("expected failure on stuck composer")
        except RuntimeError as exc:
            assert "pending input could not be cleared; nothing was typed or submitted" in str(exc)

    assert sub.text_typed == [], f"{backend}: expected no text typed, got {sub.text_typed}"
    assert sub.enters_sent == 0, f"{backend}: expected no Enter sent, got {sub.enters_sent}"
    assert "nudged" not in buf.getvalue()

    # Unknown composer at start: fails without typing or submit
    sub = StatefulSubstrate(backend_name=backend)
    sub.pane = "garbage unidentifiable text"
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         patch.object(m.time, "sleep"):
        try:
            m.session_nudge(rec["name"], "should not be typed")
            raise AssertionError("expected failure on unknown composer")
        except RuntimeError as exc:
            assert "pending input could not be cleared; nothing was typed or submitted" in str(exc)
    assert sub.text_typed == []
    assert sub.enters_sent == 0

    # 4. A merged composer: no Enter, nudge fails
    sub = StatefulSubstrate(backend_name=backend)
    sub.pane = empty_fix
    def handler_4(s, action, val):
        if action == "send_text":
            s.pane = merged_fix
        elif action == "send_keys" and val == "enter":
            s.enters_sent += 1

    sub.custom_handler = handler_4
    rec = {"name": f"s4_{backend}", "agent": "claude"}
    buf = io.StringIO()
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         patch.object(m.time, "sleep"), \
         contextlib.redirect_stdout(buf):
        try:
            m.session_nudge(rec["name"], "explicit instruction")
            raise AssertionError("expected failure on merged composer")
        except RuntimeError as exc:
            assert "the composer did not hold exactly the message; nothing was submitted" in str(exc)

    assert sub.enters_sent == 0, f"{backend}: expected no Enter sent, got {sub.enters_sent}"
    assert "nudged" not in buf.getvalue()

    # 5. Codex Pasted Content counts as holding message
    sub = StatefulSubstrate(backend_name=backend)
    sub.pane = "› \x1b[2mAsk Codex to do anything\x1b[0m\n"
    def handler_5(s, action, val):
        if action == "send_text":
            s.pane = "[Pasted Content]\n› \x1b[2mAsk Codex to do anything\x1b[0m\n"
        elif action == "send_keys" and val == "enter":
            s.pane = "› \x1b[2mAsk Codex to do anything\x1b[0m\n"

    sub.custom_handler = handler_5
    rec = {"name": f"s5_{backend}", "agent": "codex"}
    buf = io.StringIO()
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "codex_queue_send", return_value=False), \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         patch.object(m.time, "sleep"), \
         contextlib.redirect_stdout(buf):
        m.session_nudge(rec["name"], "pasted text")

    assert f"nudged {rec['name']}" in buf.getvalue()
    assert sub.enters_sent >= 1

    # 5b. Codex with stale input and Pasted Content fails exact comparison
    sub = StatefulSubstrate(backend_name=backend)
    sub.pane = "› \x1b[2mAsk Codex to do anything\x1b[0m\n"
    def handler_5b(s, action, val):
        if action == "send_text":
            s.pane = "stale input [Pasted Content]\n› \x1b[2mAsk Codex to do anything\x1b[0m\n"
        elif action == "send_keys" and val == "enter":
            s.enters_sent += 1

    sub.custom_handler = handler_5b
    rec = {"name": f"s5b_{backend}", "agent": "codex"}
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "codex_queue_send", return_value=False), \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         patch.object(m.time, "sleep"):
        try:
            m.session_nudge(rec["name"], "pasted text")
            raise AssertionError("expected failure on merged codex pasted content")
        except RuntimeError as exc:
            assert "the composer did not hold exactly the message; nothing was submitted" in str(exc)
    assert sub.enters_sent == 0

    # 5c. Refuse clearing when backspaces > 4096 would be needed
    sub = StatefulSubstrate(backend_name=backend)
    sub.pane = f"{R}\n❯ {'a' * 5000}\n{R}\n"
    def handler_5c(s, action, val):
        pass  # ctrl+u does not shorten
    sub.custom_handler = handler_5c
    rec = {"name": f"s5c_{backend}", "agent": "claude"}
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         patch.object(m.time, "sleep"):
        try:
            m.session_nudge(rec["name"], "new text")
            raise AssertionError("expected failure when > 4096 backspaces needed")
        except RuntimeError as exc:
            assert "pending input could not be cleared; nothing was typed or submitted" in str(exc)
    assert sub.enters_sent == 0

    # 6. Clean prompt, Codex queue path, and Pi, all unchanged
    # Clean prompt: starts empty
    sub = StatefulSubstrate(backend_name=backend)
    sub.pane = empty_fix
    def handler_clean(s, action, val):
        if action == "send_text":
            s.pane = f"{R}\n❯ {val}\n{R}\n"
        elif action == "send_keys" and val == "enter":
            s.pane = empty_fix

    sub.custom_handler = handler_clean
    rec = {"name": f"s6_clean_{backend}", "agent": "claude"}
    buf = io.StringIO()
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         patch.object(m.time, "sleep"), \
         contextlib.redirect_stdout(buf):
        m.session_nudge(rec["name"], "clean instruction")

    assert f"nudged {rec['name']}" in buf.getvalue()
    assert sub.ctrl_u_sent == 0
    assert sub.backspace_sent == 0
    assert sub.text_typed == ["clean instruction"]
    assert sub.enters_sent >= 1

    # Codex queue path
    sub = StatefulSubstrate(backend_name=backend)
    rec = {"name": f"s6_codex_{backend}", "agent": "codex", "codex_thread_id": "tid"}
    buf = io.StringIO()
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "codex_queue_send", return_value=True) as qsend, \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         contextlib.redirect_stdout(buf):
        m.session_nudge(rec["name"], "via queue")

    assert qsend.called
    assert f"nudged {rec['name']} (codex queue)" in buf.getvalue()
    assert len(sub.actions) == 0

    # Pi agent: unchanged legacy path
    sub = StatefulSubstrate(backend_name=backend)
    rec = {"name": f"s6_pi_{backend}", "agent": "pi"}
    buf = io.StringIO()
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         patch.object(m.time, "sleep"), \
         contextlib.redirect_stdout(buf):
        m.session_nudge(rec["name"], "pi message")

    assert f"nudged {rec['name']}" in buf.getvalue()
    assert sub.ctrl_u_sent == 1
    assert sub.backspace_sent == 0
    assert sub.text_typed == ["pi message"]
    assert sub.enters_sent >= 1

    # 7. Antigravity agent coverage
    sub = StatefulSubstrate(backend_name=backend)
    sub.pane = f"{R}\n> \x1b[0m\n{R}\n? for shortcuts · Gemini\n"
    def handler_agy(s, action, val):
        if action == "send_text":
            s.pane = f"{R}\n> \x1b[0m{val}\x1b[0m\n{R}\n? for shortcuts · Gemini\n"
        elif action == "send_keys" and val == "enter":
            s.pane = f"{R}\n> \x1b[0m\n{R}\n? for shortcuts · Gemini\n"

    sub.custom_handler = handler_agy
    rec = {"name": f"s7_agy_{backend}", "agent": "antigravity"}
    buf = io.StringIO()
    with patch.object(m, "_require_running", return_value=(None, rec)), \
         patch.object(m, "backend_for_name", return_value=(sub, {})), \
         patch.object(m.time, "sleep"), \
         contextlib.redirect_stdout(buf):
        m.session_nudge(rec["name"], "hello antigravity")

    assert f"nudged {rec['name']}" in buf.getvalue()
    assert sub.enters_sent >= 1

print("ok - session nudge clear, wrapped input, backspace fallback, exact comparison and legacy paths passed")
PY
