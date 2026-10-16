#!/usr/bin/env bash
# TASK-HSS-002: identify the dedicated tmux server's namespace read-only.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 - "$here" <<'PY'
import contextlib
import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import socket
import struct
import sys
import tempfile
import threading
from types import SimpleNamespace
from unittest.mock import patch

scripts = Path(sys.argv[1])
for key in list(os.environ):
    if key.startswith(("NOGG_", "HERDR_")) or key in {"TMUX", "TMUX_TMPDIR"}:
        os.environ.pop(key, None)
sys.path.insert(0, str(scripts / "lib"))
from session_backend_tmux import server_namespace

loader = importlib.machinery.SourceFileLoader("nogg_under_test", str(scripts / "nogg"))
spec = importlib.util.spec_from_loader("nogg_under_test", loader)
nogg = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = nogg
spec.loader.exec_module(nogg)

with tempfile.TemporaryDirectory(prefix="nogg.", dir="/tmp") as directory:
    root = Path(directory)
    tmux_dir = root / f"tmux-{os.getuid()}"
    tmux_dir.mkdir()
    path = tmux_dir / "nogging"
    assert len(os.fsencode(path)) < 108, path
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(path))
    listener.listen(1)
    finished = threading.Event()
    def serve():
        conn, _ = listener.accept()
        conn.close()
        finished.set()
    thread = threading.Thread(target=serve, daemon=True)
    thread.start()
    config = {"session_tmux_socket": "nogging"}
    env = patch.dict(os.environ, TMUX_TMPDIR=directory)
    with env, patch("session_backend_tmux._namespace_links",
                    side_effect=lambda pid: ("pid:[host]", "mnt:[host]") if pid == "self"
                    else ("pid:[host]", "mnt:[host]")):
        result = server_namespace(config)
        assert result["class"] == "host" and result["pid"] > 0, result
    assert finished.wait(1)
    listener.close()

    # Namespace strings are opaque; either differing identity makes it sandboxed.
    with patch.dict(os.environ, TMUX_TMPDIR=directory), \
         patch("session_backend_tmux.socket.socket", side_effect=OSError("no socket")):
        assert server_namespace(config)["class"] == "unknown"
    with patch.dict(os.environ, TMUX_TMPDIR=directory):
        assert server_namespace(config)["class"] == "down"
    path.unlink()
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(str(path))
    stale.close()
    with patch.dict(os.environ, TMUX_TMPDIR=directory):
        assert server_namespace(config)["class"] == "down"
    path.unlink()

    # Exercise PID 0 from peer credentials and both namespace comparisons with
    # a fake socket. No PID assumptions and no process signals are involved.
    class PeerSocket:
        def __init__(self, pid): self.pid = pid
        def settimeout(self, _): pass
        def connect(self, _): pass
        def getsockopt(self, *_): return struct.pack("3i", os.getuid(), self.pid, os.getgid())
        def close(self): pass
    for fenced, pid, expected in ((True, 0, "outside"), (False, 0, "unknown"),
                                  (True, 123, "sandboxed")):
        with patch.dict(os.environ, TMUX_TMPDIR=directory,
                        NOGG_OPENSPEC_FENCED="1" if fenced else ""), \
             patch("session_backend_tmux.socket.socket", return_value=PeerSocket(pid)):
            assert server_namespace(config)["class"] == expected
    with patch.dict(os.environ, TMUX_TMPDIR=directory), \
         patch("session_backend_tmux.socket.socket", return_value=PeerSocket(123)), \
         patch("session_backend_tmux._namespace_links", side_effect=[("pid:[a]", "mnt:[a]"),
                                                                       ("pid:[b]", "mnt:[a]")]):
        assert server_namespace(config)["class"] == "sandboxed"

    # Reporting paths are advisory and never invoke a tmux mutation.
    with patch.object(nogg, "tmux_server_namespace", return_value={"class": "sandboxed", "pid": 123}):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), patch.object(nogg, "session_records", return_value=[]):
            nogg.session_list()
        assert "NOTE: tmux server PID 123 is sandboxed" in out.getvalue()

        out = io.StringIO()
        fake_path = root / "locks"
        with contextlib.redirect_stdout(out), \
             patch.object(nogg, "_systemctl", return_value=SimpleNamespace(stdout="inactive")), \
             patch.object(nogg, "_linger_on", return_value=False), \
             patch.object(nogg, "ORCHESTRATOR_LOCKS", fake_path), \
             patch.object(nogg, "orchestrator_live_session", return_value=None):
            nogg.orchestrator_status()
        assert "tmux server: sandboxed" in out.getvalue()

        assert nogg.tmux_sandboxed_warning() == (
            "tmux server PID 123 is sandboxed; every session on this server ends with that namespace")

        out = io.StringIO()
        neutral = {
            "session_helper_diagnostics": [], "validate": ({}, [], [], []),
            "resolve_agent_state_roots": None, "herdr_doctor_diagnostics": ([], [], []),
            "mapping_health_lines": [], "archive_ready_changes": [],
            "multi_machine_enabled": False, "codex_sandbox_diagnosis": [],
            "stale_codex_rule_lines": [], "recover_scan": ([], []),
            "persona_mismatch_notes": [], "launch_profile_notes": [],
            "supervised_launch_permission_notes": [], "model_selection_notes": [],
            "blocked_running_sessions_notes": [], "usage_collection_notes": [],
        }
        sentinel = root / "sentinel"
        sentinel.touch()
        with contextlib.redirect_stdout(out), contextlib.ExitStack() as stack:
            for name, value in neutral.items():
                stack.enter_context(patch.object(nogg, name, return_value=value, create=True))
            stack.enter_context(patch.object(nogg, "tool_on_path", return_value=True))
            stack.enter_context(patch.object(nogg, "SENTINEL", sentinel))
            nogg.doctor()
        assert "WARN  tmux server PID 123 is sandboxed" in out.getvalue()

print("session tmux server namespace: ok")
PY
