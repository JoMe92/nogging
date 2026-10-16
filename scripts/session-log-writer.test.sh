#!/usr/bin/env bash
# Tests for byte-based, bounded session log writer and rotation archive (TASK-HHB-008, Decision 9).
#
# Covers:
#   - contract handshake (version 1, positional 3, features: ["byte-stream"]);
#   - CLI argument validation;
#   - helper contract check in nogg (accepts byte-stream, rejects legacy);
#   - a no-LF stream through an open pipe grows live before EOF;
#   - 3 MiB no-LF stream with 1 MiB limit: every generation is <= 1 MiB and depth is respected;
#   - byte-exact content (ANSI escapes, raw binary, invalid UTF-8, null bytes);
#   - cleanup archives the active log and all rotated generations under the same timestamp.
set -euo pipefail

# Clean inherited environment per Decision 1
for v in $(compgen -v NOGG_ 2>/dev/null || true); do unset "$v"; done
for v in $(compgen -v HERDR_ 2>/dev/null || true); do unset "$v"; done
unset TMUX NOGGING_ROOT

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
writer="$repo_root/scripts/session-log-writer"
nogg="$repo_root/scripts/nogg"

python3 - "$repo_root" "$writer" "$nogg" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

repo_root = Path(sys.argv[1]).resolve()
writer_bin = Path(sys.argv[2]).resolve()
nogg_bin = Path(sys.argv[3]).resolve()


def test_contract_and_cli():
    # Valid contract query
    res = subprocess.run([str(writer_bin), "--contract"], capture_output=True, text=True)
    assert res.returncode == 0, f"contract exit code: {res.returncode}"
    contract = json.loads(res.stdout)
    assert contract.get("version") == 1
    assert contract.get("positional") == 3
    assert contract.get("features") == ["byte-stream"]

    # Extra arguments to contract must fail
    res = subprocess.run([str(writer_bin), "--contract", "extra"], capture_output=True)
    assert res.returncode == 2

    # Missing arguments must fail
    res = subprocess.run([str(writer_bin)], capture_output=True)
    assert res.returncode == 2
    res = subprocess.run([str(writer_bin), "only-log"], capture_output=True)
    assert res.returncode == 2

    # Malformed non-integer or invalid values
    res = subprocess.run([str(writer_bin), "log", "not-an-int", "2"], capture_output=True)
    assert res.returncode == 2
    res = subprocess.run([str(writer_bin), "log", "0", "2"], capture_output=True)
    assert res.returncode == 2
    res = subprocess.run([str(writer_bin), "log", "100", "-1"], capture_output=True)
    assert res.returncode == 2

    print("ok - contract handshake and CLI argument validation")


def test_nogg_contract_check():
    with tempfile.TemporaryDirectory(prefix="test-contract-") as tmp:
        tmp_dir = Path(tmp)
        repo = tmp_dir / "repo"
        repo.mkdir()
        (repo / ".nogging").mkdir()
        (repo / ".nogging/config.json").write_text(json.dumps({
            "beads_command": "bd",
            "session_state_dir": ".nogging/state/sessions",
        }))
        scripts = repo / "scripts"
        scripts.mkdir()

        # Copy nogg and create a stub writer
        shutil.copy2(nogg_bin, scripts / "nogg")
        (scripts / "nogg").chmod(0o755)

        # 1. With current writer, contract check succeeds
        shutil.copy2(writer_bin, scripts / "session-log-writer")
        (scripts / "session-log-writer").chmod(0o755)

        code = """
import sys
from pathlib import Path
from importlib.machinery import SourceFileLoader
nogg = SourceFileLoader('nogg', sys.argv[1]).load_module()
checks = nogg.session_helper_diagnostics()
writer_checks = [ok for name, ok in checks if 'session-log-writer' in name]
assert writer_checks and all(writer_checks), f'diagnostics failed: {checks}'
"""
        res = subprocess.run([sys.executable, "-c", code, str(scripts / "nogg")],
                             cwd=str(repo), capture_output=True, text=True)
        assert res.returncode == 0, f"nogg diagnostics failed: {res.stderr}"

        # 2. Legacy writer lacking 'byte-stream' feature must be rejected
        legacy = scripts / "session-log-writer"
        legacy.write_text('#!/bin/sh\n[ "$1" = "--contract" ] && echo \'{"version":1,"positional":3}\' && exit 0\nexit 2\n')
        legacy.chmod(0o755)

        code_legacy = """
import sys
from pathlib import Path
from importlib.machinery import SourceFileLoader
nogg = SourceFileLoader('nogg', sys.argv[1]).load_module()
checks = nogg.session_helper_diagnostics()
writer_checks = [ok for name, ok in checks if 'session-log-writer' in name]
assert writer_checks and not any(writer_checks), f'legacy writer should fail: {checks}'
"""
        res = subprocess.run([sys.executable, "-c", code_legacy, str(scripts / "nogg")],
                             cwd=str(repo), capture_output=True, text=True)
        assert res.returncode == 0, f"legacy writer rejection failed: {res.stderr}"

    print("ok - nogg requires byte-stream feature in session-log-writer contract")


def test_no_lf_live_growth():
    with tempfile.TemporaryDirectory(prefix="test-live-") as tmp:
        log_file = Path(tmp) / "live.log"
        # Start writer with 1 MiB limit, depth 3
        proc = subprocess.Popen(
            [str(writer_bin), str(log_file), "1048576", "3"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        try:
            # File should exist at startup
            deadline = time.time() + 2.0
            while not log_file.exists() and time.time() < deadline:
                time.sleep(0.02)
            assert log_file.exists(), "log file must be created on startup"

            # Write chunk 1 without any newline
            chunk1 = b"LIVE_STREAM_CHUNK_ONE_NO_NEWLINE"
            proc.stdin.write(chunk1)
            proc.stdin.flush()

            deadline = time.time() + 2.0
            while log_file.stat().st_size < len(chunk1) and time.time() < deadline:
                time.sleep(0.02)

            assert log_file.stat().st_size == len(chunk1), (
                f"expected size {len(chunk1)} before EOF, got {log_file.stat().st_size}"
            )
            assert log_file.read_bytes() == chunk1

            # Write chunk 2 without any newline while pipe stays open
            chunk2 = b"_CHUNK_TWO_NO_NEWLINE_EITHER"
            proc.stdin.write(chunk2)
            proc.stdin.flush()

            expected_size = len(chunk1) + len(chunk2)
            deadline = time.time() + 2.0
            while log_file.stat().st_size < expected_size and time.time() < deadline:
                time.sleep(0.02)

            assert log_file.stat().st_size == expected_size, (
                f"expected size {expected_size} before EOF, got {log_file.stat().st_size}"
            )
            assert log_file.read_bytes() == chunk1 + chunk2

        finally:
            proc.stdin.close()
            assert proc.wait(timeout=5) == 0

    print("ok - no-LF live growth: log grows before EOF while writer pipe remains open")


def test_3mib_bound_and_rotation():
    with tempfile.TemporaryDirectory(prefix="test-rot-") as tmp:
        log_file = Path(tmp) / "rot.log"
        one_mib = 1024 * 1024
        three_mib = 3 * one_mib
        depth = 2

        # 3 MiB stream without a single newline (all 'A')
        # Use a generator pattern of non-newline bytes
        pattern = b"0123456789abcdef" * (three_mib // 16)
        assert len(pattern) == three_mib
        assert b"\n" not in pattern

        proc = subprocess.Popen(
            [str(writer_bin), str(log_file), str(one_mib), str(depth)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        # Feed 3 MiB in chunks to writer
        chunk_size = 64 * 1024
        for offset in range(0, three_mib, chunk_size):
            proc.stdin.write(pattern[offset:offset + chunk_size])
        proc.stdin.close()

        assert proc.wait(timeout=10) == 0

        # Inspect resulting files
        assert log_file.exists(), "active log must exist"
        rot1 = log_file.with_name(f"{log_file.name}.1")
        rot2 = log_file.with_name(f"{log_file.name}.2")
        rot3 = log_file.with_name(f"{log_file.name}.3")

        assert rot1.exists(), "rot.log.1 must exist"
        assert rot2.exists(), "rot.log.2 must exist"
        assert not rot3.exists(), "rot.log.3 must not exist per depth=2"

        # Every generation must be <= max_bytes
        for p in (log_file, rot1, rot2):
            size = p.stat().st_size
            assert size <= one_mib, f"{p.name} exceeded 1 MiB bound: {size} bytes"
            assert size == one_mib, f"{p.name} expected exact 1 MiB generation: {size} bytes"

        # Content ordering:
        # rot2 was generated first (bytes 0..1MiB)
        # rot1 was generated second (bytes 1MiB..2MiB)
        # active log was generated third (bytes 2MiB..3MiB)
        assert rot2.read_bytes() == pattern[0:one_mib]
        assert rot1.read_bytes() == pattern[one_mib:2 * one_mib]
        assert log_file.read_bytes() == pattern[2 * one_mib:3 * one_mib]

    print("ok - 3 MiB no-LF stream with 1 MiB limit: bounded generations and depth respected")


def test_byte_exact_content():
    with tempfile.TemporaryDirectory(prefix="test-exact-") as tmp:
        log_file = Path(tmp) / "exact.log"

        # Mixed arbitrary bytes: ANSI escape sequences, all 256 bytes, invalid UTF-8, nulls
        test_payload = (
            b"\x1b[31;1mRed Bold Text\x1b[0m\r\n"
            b"Tab\tSeparated\x00Null\x00Bytes\n"
            + bytes(range(256))
            + b"\xff\xfe\x80\xc0\xc1"  # Invalid UTF-8 bytes
            + b"\x1b[2J\x1b[H\x1b[?25h"  # Terminal controls
        )

        proc = subprocess.Popen(
            [str(writer_bin), str(log_file), "65536", "2"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        proc.stdin.write(test_payload)
        proc.stdin.close()
        assert proc.wait(timeout=5) == 0

        recorded = log_file.read_bytes()
        assert recorded == test_payload, "recorded content must be byte-exact"

    print("ok - byte-exact content preserved across escapes, controls, nulls, and non-UTF-8")


def test_cleanup_archiving_all_generations():
    with tempfile.TemporaryDirectory(prefix="test-cleanup-") as tmp:
        tmp_dir = Path(tmp)
        repo = tmp_dir / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@test.local"], check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "--allow-empty", "-qm", "init"], check=True)

        (repo / ".nogging").mkdir()
        (repo / ".nogging/config.json").write_text(json.dumps({
            "beads_command": "bd",
            "session_state_dir": ".nogging/state/sessions",
        }))

        state_dir = repo / ".nogging/state/sessions"
        state_dir.mkdir(parents=True)

        scripts = repo / "scripts"
        scripts.mkdir()
        shutil.copy2(nogg_bin, scripts / "nogg")
        (scripts / "nogg").chmod(0o755)
        shutil.copytree(repo_root / "scripts/lib", scripts / "lib")

        # Set up stub bd and stub tmux
        stub_bin = tmp_dir / "bin"
        stub_bin.mkdir()
        (stub_bin / "bd").write_text("#!/bin/sh\nexit 0\n")
        (stub_bin / "bd").chmod(0o755)
        (stub_bin / "tmux").write_text("#!/bin/sh\nexit 0\n")
        (stub_bin / "tmux").chmod(0o755)

        session_name = "test-session-archive"
        log_file = state_dir / f"{session_name}.log"
        rot1 = state_dir / f"{session_name}.log.1"
        rot2 = state_dir / f"{session_name}.log.2"

        content_active = b"ACTIVE_LOG_CONTENT"
        content_rot1 = b"ROTATED_1_CONTENT"
        content_rot2 = b"ROTATED_2_CONTENT"

        log_file.write_bytes(content_active)
        rot1.write_bytes(content_rot1)
        rot2.write_bytes(content_rot2)

        session_record = {
            "name": session_name,
            "role": "lead",
            "state": "stopped",
            "log_path": str(log_file),
            "owner": "test",
        }
        (state_dir / f"{session_name}.json").write_text(json.dumps(session_record))

        # Run session cleanup
        env = {
            **os.environ,
            "PATH": f"{stub_bin}:{os.environ.get('PATH', '')}",
            "NOGGING_ROOT": str(repo),
        }
        res = subprocess.run([str(scripts / "nogg"), "session", "cleanup", session_name],
                             cwd=str(repo), env=env, capture_output=True, text=True)
        assert res.returncode == 0, f"session cleanup failed: {res.stdout}\n{res.stderr}"

        # Original unarchived files must no longer exist
        assert not log_file.exists(), "original active log must be removed after cleanup"
        assert not rot1.exists(), "original rot1 must be removed after cleanup"
        assert not rot2.exists(), "original rot2 must be removed after cleanup"

        # Rotated archived files must exist
        archived_active = list(state_dir.glob(f"{session_name}.log.archived-*"))
        assert len(archived_active) == 1, f"expected 1 archived active log, found: {archived_active}"

        archived_rot1 = list(state_dir.glob(f"{session_name}.log.1.archived-*"))
        assert len(archived_rot1) == 1, f"expected 1 archived rot1, found: {archived_rot1}"

        archived_rot2 = list(state_dir.glob(f"{session_name}.log.2.archived-*"))
        assert len(archived_rot2) == 1, f"expected 1 archived rot2, found: {archived_rot2}"

        # Extract timestamps
        ts_active = archived_active[0].name.split(".archived-", 1)[1]
        ts_rot1 = archived_rot1[0].name.split(".archived-", 1)[1]
        ts_rot2 = archived_rot2[0].name.split(".archived-", 1)[1]

        assert ts_active == ts_rot1 == ts_rot2, (
            f"all generations must be archived under the same timestamp: {ts_active}, {ts_rot1}, {ts_rot2}"
        )

        # Contents must match original generations
        assert archived_active[0].read_bytes() == content_active
        assert archived_rot1[0].read_bytes() == content_rot1
        assert archived_rot2[0].read_bytes() == content_rot2

    print("ok - cleanup archives active log and all rotated generations under the same timestamp")


if __name__ == "__main__":
    test_contract_and_cli()
    test_nogg_contract_check()
    test_no_lf_live_growth()
    test_3mib_bound_and_rotation()
    test_byte_exact_content()
    test_cleanup_archiving_all_generations()
    print("All session-log-writer tests passed.")
PY
