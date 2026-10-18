#!/usr/bin/env bash
# Tests for scripts/session-pty-recorder:
# TUI I/O, resize, rotation, writer failure, and pane-close flush (HDR-004).
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
recorder="$here/session-pty-recorder"
writer="$here/session-log-writer"

if [ ! -x "$recorder" ]; then
  echo "FAIL - $recorder is not executable" >&2
  exit 1
fi

python3 - "$recorder" "$writer" <<'PY'
from __future__ import annotations

import fcntl
import json
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path

recorder_bin = sys.argv[1]
log_writer_bin = sys.argv[2]


def test_contract_and_args():
    res = subprocess.run([recorder_bin, "--contract"], capture_output=True, text=True)
    assert res.returncode == 0, f"expected 0, got {res.returncode}"
    contract = json.loads(res.stdout)
    assert contract.get("version") == 1
    assert contract.get("positional") == 3

    # Extra arguments to contract must fail
    res = subprocess.run([recorder_bin, "--contract", "extra"], capture_output=True, text=True)
    assert res.returncode == 2

    # Missing / malformed arguments must fail
    res = subprocess.run([recorder_bin], capture_output=True, text=True)
    assert res.returncode == 2

    res = subprocess.run([recorder_bin, "log", "100", "2", "no_dash_dash", "echo"], capture_output=True, text=True)
    assert res.returncode == 2

    res = subprocess.run([recorder_bin, "log", "not_an_int", "2", "--", "echo"], capture_output=True, text=True)
    assert res.returncode == 2

    res = subprocess.run([recorder_bin, "log", "-5", "2", "--", "echo"], capture_output=True, text=True)
    assert res.returncode == 2

    res = subprocess.run([recorder_bin, "log", "100", "2", "--"], capture_output=True, text=True)
    assert res.returncode == 2

    print("ok - contract and argument validation")


def test_tui_io_and_exit_codes():
    with tempfile.TemporaryDirectory() as temp:
        temp_dir = Path(temp)
        log_file = temp_dir / "session.log"

        child_script = """
import sys, os
sys.stdout.write("\\x1b[32mCOLOR_OUTPUT\\x1b[0m\\n")
sys.stdout.flush()
line = sys.stdin.readline().strip()
sys.stdout.write(f"ECHO:{line}\\n")
sys.stdout.flush()
sys.exit(42)
"""
        proc = subprocess.Popen(
            [recorder_bin, str(log_file), "100000", "2", "--", sys.executable, "-c", child_script],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        stdout, stderr = proc.communicate(input="HELLO_PTY\n", timeout=10)
        assert proc.returncode == 42, f"expected exit code 42, got {proc.returncode}"
        assert "\x1b[32mCOLOR_OUTPUT\x1b[0m" in stdout
        assert "ECHO:HELLO_PTY" in stdout

        # Verify output also captured in log
        assert log_file.exists()
        log_content = log_file.read_text()
        assert "\x1b[32mCOLOR_OUTPUT\x1b[0m" in log_content
        assert "ECHO:HELLO_PTY" in log_content

        # Verify exit code 0
        proc0 = subprocess.run(
            [recorder_bin, str(log_file), "100000", "2", "--", sys.executable, "-c", "import sys; sys.exit(0)"],
            capture_output=True,
        )
        assert proc0.returncode == 0

        # Verify exit status on signal termination
        sig_script = "import os, signal; os.kill(os.getpid(), signal.SIGTERM)"
        proc_sig = subprocess.run(
            [recorder_bin, str(log_file), "100000", "2", "--", sys.executable, "-c", sig_script],
            capture_output=True,
        )
        assert proc_sig.returncode == 128 + signal.SIGTERM, f"expected {128 + signal.SIGTERM}, got {proc_sig.returncode}"

    print("ok - transparent TUI I/O and exit status pass-through")


def test_window_resize_sigwinch():
    with tempfile.TemporaryDirectory() as temp:
        log_file = Path(temp) / "session.log"
        outer_m, outer_s = pty.openpty()

        initial_ws = struct.pack("HHHH", 24, 80, 0, 0)
        fcntl.ioctl(outer_m, termios.TIOCSWINSZ, initial_ws)

        child_code = """
import sys, os, signal, fcntl, termios, struct, time
def on_winch(s, f):
    ws = fcntl.ioctl(0, termios.TIOCGWINSZ, b'\\x00'*8)
    r, c, _, _ = struct.unpack('HHHH', ws)
    sys.stdout.write(f"RESIZED:{r}x{c}\\n")
    sys.stdout.flush()

signal.signal(signal.SIGWINCH, on_winch)
ws = fcntl.ioctl(0, termios.TIOCGWINSZ, b'\\x00'*8)
r, c, _, _ = struct.unpack('HHHH', ws)
sys.stdout.write(f"INITIAL:{r}x{c}\\n")
sys.stdout.flush()

for _ in range(50):
    time.sleep(0.1)
"""
        proc = subprocess.Popen(
            [recorder_bin, str(log_file), "100000", "2", "--", sys.executable, "-c", child_code],
            stdin=outer_s,
            stdout=outer_s,
            stderr=outer_s,
            close_fds=True,
        )
        os.close(outer_s)

        buf = b""
        deadline = time.time() + 5
        while b"INITIAL:" not in buf and time.time() < deadline:
            r, _, _ = select.select([outer_m], [], [], 0.2)
            if outer_m in r:
                buf += os.read(outer_m, 1024)
        assert b"INITIAL:24x80" in buf, f"did not get expected initial size: {buf}"

        # Trigger resize
        new_ws = struct.pack("HHHH", 35, 110, 0, 0)
        fcntl.ioctl(outer_m, termios.TIOCSWINSZ, new_ws)
        os.kill(proc.pid, signal.SIGWINCH)

        deadline = time.time() + 5
        while b"RESIZED:35x110" not in buf and time.time() < deadline:
            r, _, _ = select.select([outer_m], [], [], 0.2)
            if outer_m in r:
                buf += os.read(outer_m, 1024)
        assert b"RESIZED:35x110" in buf, f"did not get resized size: {buf}"

        proc.terminate()
        proc.wait(timeout=5)
        os.close(outer_m)

    print("ok - initial window size and SIGWINCH resize propagation")


def test_log_rotation():
    with tempfile.TemporaryDirectory() as temp:
        log_file = Path(temp) / "session.log"
        # max_bytes 100, depth 2
        # Print lines of 30 chars each; 6 lines = 180 chars -> triggers rotation
        child_code = """
import sys, time
for i in range(10):
    sys.stdout.write(f"LINE_{i:02d}_0123456789012345678901234\\n")
    sys.stdout.flush()
    time.sleep(0.02)
sys.exit(0)
"""
        proc = subprocess.run(
            [recorder_bin, str(log_file), "100", "2", "--", sys.executable, "-c", child_code],
            capture_output=True,
            timeout=10,
        )
        assert proc.returncode == 0
        assert log_file.exists()
        rot1 = Path(str(log_file) + ".1")
        rot2 = Path(str(log_file) + ".2")
        rot3 = Path(str(log_file) + ".3")

        assert rot1.exists(), "rotated log .1 should exist"
        assert rot2.exists(), "rotated log .2 should exist"
        assert not rot3.exists(), "rotated log .3 should be pruned per depth=2"

    print("ok - size-based log rotation respecting depth")


def test_writer_failure_handling():
    with tempfile.TemporaryDirectory() as temp:
        log_file = Path(temp) / "session.log"

        # Subcase A: Log writer executable fails to launch
        env_broken = dict(os.environ, NOGG_SESSION_LOG_WRITER="/nonexistent/bin/session-log-writer")
        proc = subprocess.run(
            [recorder_bin, str(log_file), "1000", "2", "--", sys.executable, "-c", "import sys; print('RUN_OK'); sys.exit(0)"],
            env=env_broken,
            capture_output=True,
            text=True,
            timeout=5,
        )
        assert proc.returncode == 0, f"recorder should not crash when writer missing: code {proc.returncode}, stdout={proc.stdout!r}, stderr={proc.stderr!r}"
        assert "RUN_OK" in proc.stdout
        assert log_file.exists()
        log_content = log_file.read_text()
        assert "# log capture failed" in log_content

        # Subcase B: Log writer killed during session
        log_file_2 = Path(temp) / "session2.log"
        child_code = """
import sys, time
sys.stdout.write("READY_STAGE_1\\n")
sys.stdout.flush()
time.sleep(1.0)
sys.stdout.write("STAGE_2_AFTER_WRITER_DIED\\n")
sys.stdout.flush()
sys.exit(0)
"""
        proc2 = subprocess.Popen(
            [recorder_bin, str(log_file_2), "1000", "2", "--", sys.executable, "-c", child_code],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        # Wait for READY_STAGE_1
        first_line = proc2.stdout.readline()
        assert "READY_STAGE_1" in first_line

        # Find session-log-writer process and kill it
        time.sleep(0.1)
        killed_writer = False
        try:
            pgrep = subprocess.run(["pgrep", "-f", f"session-log-writer {log_file_2}"], capture_output=True, text=True)
            for pid_str in pgrep.stdout.strip().split():
                if pid_str:
                    os.kill(int(pid_str), signal.SIGKILL)
                    killed_writer = True
        except Exception:
            pass
        assert killed_writer, "should find and kill session-log-writer process"

        stdout2, _ = proc2.communicate(timeout=5)
        assert proc2.returncode == 0, f"agent and recorder must complete successfully: got {proc2.returncode}"
        assert "STAGE_2_AFTER_WRITER_DIED" in stdout2

        assert log_file_2.exists()
        log2_text = log_file_2.read_text()
        assert "# log capture failed" in log2_text

    print("ok - writer failure keeps agent running and notes failure")


def test_pane_close_flush():
    with tempfile.TemporaryDirectory() as temp:
        log_file = Path(temp) / "pane_close.log"

        child_code = """
import sys, time, signal
# Print initial line
sys.stdout.write("INITIAL_LINE\\n")
sys.stdout.flush()
# Print trailing tail WITHOUT immediate newline
sys.stdout.write("TAIL_OUTPUT_BEFORE_CLOSE")
sys.stdout.flush()
# Sleep and wait for signal
for _ in range(50):
    time.sleep(0.1)
"""
        # Run recorder in its own process group
        proc = subprocess.Popen(
            [recorder_bin, str(log_file), "10000", "2", "--", sys.executable, "-c", child_code],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            text=True,
        )

        first_line = proc.stdout.readline()
        assert "INITIAL_LINE" in first_line

        # Verify writer is running in its own session / process group
        time.sleep(0.1)
        pgrep = subprocess.run(["pgrep", "-f", f"session-log-writer {log_file}"], capture_output=True, text=True)
        writer_pids = [int(p) for p in pgrep.stdout.strip().split() if p]
        assert writer_pids, "writer must be running"
        writer_pid = writer_pids[0]

        recorder_sid = os.getsid(proc.pid)
        writer_sid = os.getsid(writer_pid)
        assert writer_sid != recorder_sid, (
            f"writer must run in independent session (got writer sid {writer_sid} == recorder sid {recorder_sid})"
        )

        # Simulate pane close: send SIGHUP to the recorder's process group
        os.killpg(proc.pid, signal.SIGHUP)

        proc.wait(timeout=5)
        # SIGHUP exit status is 128 + 1 = 129
        assert proc.returncode == 128 + signal.SIGHUP, f"expected {128 + signal.SIGHUP}, got {proc.returncode}"

        # Verify writer flushed the tail output into the log
        assert log_file.exists()
        log_content = log_file.read_text()
        assert "INITIAL_LINE" in log_content
        assert "TAIL_OUTPUT_BEFORE_CLOSE" in log_content, (
            f"log missing unbuffered tail on pane close: {log_content!r}"
        )

    print("ok - pane-close flush under SIGHUP with independent session writer")


if __name__ == "__main__":
    test_contract_and_args()
    test_tui_io_and_exit_codes()
    test_window_resize_sigwinch()
    test_log_rotation()
    test_writer_failure_handling()
    test_pane_close_flush()
    print("ALL RECORDER TESTS PASSED")
PY

echo "PASS - scripts/session-pty-recorder.test.sh"
