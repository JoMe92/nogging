#!/usr/bin/env bash
# Conditional, read-only herdr doctor checks (TASK-HDR-009, design Decision 12).
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
stub_bin = source / "scripts/fixtures/herdr/bin/herdr"

with tempfile.TemporaryDirectory(prefix="doc-test-") as temp:
    temp_dir = Path(temp).resolve()
    repo = temp_dir / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "Test"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "test@test.local"], check=True)
    subprocess.run(["git", "-C", str(repo), "commit", "--allow-empty", "-qm", "init"], check=True)

    # Copy scripts/ and templates/ necessary for nogg to function
    (repo / "scripts").mkdir(parents=True)
    shutil.copy2(source / "scripts/nogg", repo / "scripts/nogg")
    (repo / "scripts/nogg").chmod(0o755)
    shutil.copytree(source / "scripts/lib", repo / "scripts/lib")
    shutil.copy2(source / "scripts/session-launch", repo / "scripts/session-launch")
    shutil.copy2(source / "scripts/session-log-writer", repo / "scripts/session-log-writer")
    shutil.copy2(source / "scripts/openspec-sandbox", repo / "scripts/openspec-sandbox")
    shutil.copy2(source / "scripts/session-pty-recorder", repo / "scripts/session-pty-recorder")
    (repo / "scripts/session-pty-recorder").chmod(0o755)

    (repo / ".nogging").mkdir(parents=True)
    base_config = {
        "beads_command": "bd",
        "session_state_dir": ".nogging/state/sessions"
    }
    (repo / ".nogging/config.json").write_text(json.dumps(base_config))

    stub_bin_dir = temp_dir / "stub-bin"
    stub_bin_dir.mkdir()
    (stub_bin_dir / "dolt").write_text("#!/usr/bin/env bash\nexit 0\n")
    (stub_bin_dir / "dolt").chmod(0o755)
    (stub_bin_dir / "bd").write_text(
        "#!/usr/bin/env bash\n"
        "set -euo pipefail\n"
        "if [[ \"$*\" == *\"--json\"* ]] || [[ \"${1:-}\" == \"list\" ]] || [[ \"${1:-}\" == \"show\" ]] || [[ \"${1:-}\" == \"dep\" ]]; then\n"
        "  echo '[]'\n"
        "  exit 0\n"
        "fi\n"
        "if [[ \"${1:-}\" == \"branch\" ]]; then\n"
        "  echo '* main'\n"
        "  exit 0\n"
        "fi\n"
        "exit 0\n"
    )
    (stub_bin_dir / "bd").chmod(0o755)

    env = os.environ.copy()
    env["NOGGING_ROOT"] = str(repo)
    env["PATH"] = f"{stub_bin_dir}:{source / 'scripts/fixtures/herdr/bin'}:{os.environ.get('PATH', '')}"
    herdr_stub_dir = temp_dir / "herdr-stub"
    herdr_stub_dir.mkdir()
    env["HERDR_STUB_DIR"] = str(herdr_stub_dir)

    def run_doctor(extra_env=None):
        cmd_env = env.copy()
        if extra_env:
            cmd_env.update(extra_env)
        return subprocess.run([str(repo / "scripts/nogg"), "doctor"],
                              cwd=repo, env=cmd_env, text=True, capture_output=True)

    # 1. Unused case: session_backend absent/tmux and no herdr records
    # Doctor must print nothing about herdr.
    res = run_doctor()
    assert res.returncode == 0, f"doctor failed: {res.stderr}\n{res.stdout}"
    assert "herdr" not in res.stdout.lower(), f"doctor output contained herdr when unused: {res.stdout}"

    # 2. Retired case: session_backend absent/tmux and only a retired herdr record exists
    # Doctor must print nothing about herdr.
    sessions_dir = repo / ".nogging/state/sessions"
    sessions_dir.mkdir(parents=True, exist_ok=True)
    retired_rec = {
        "name": "retired-herdr",
        "backend": "herdr",
        "bead_id": "SPEC-1",
        "state": "retired"
    }
    (sessions_dir / "retired-herdr.json").write_text(json.dumps(retired_rec))
    res = run_doctor()
    assert res.returncode == 0, f"doctor failed: {res.stderr}\n{res.stdout}"
    assert "herdr" not in res.stdout.lower(), f"doctor output contained herdr for retired record: {res.stdout}"

    # 3. Configured as backend: missing herdr binary -> FAIL
    cfg_herdr = base_config.copy()
    cfg_herdr["session_backend"] = "herdr"
    cfg_herdr["session_herdr_command"] = "/missing/nonexistent/herdr"
    (repo / ".nogging/config.json").write_text(json.dumps(cfg_herdr))

    res = run_doctor()
    assert res.returncode == 1, f"doctor should have failed with missing binary: {res.stdout}"
    assert any("FAIL" in line and "/missing/nonexistent/herdr" in line for line in res.stdout.splitlines()), \
        f"expected FAIL naming missing binary: {res.stdout}"
    # Restart note must be shown whenever herdr diagnostics are shown
    assert "server restart ends every nogging herdr session" in res.stdout.lower(), \
        f"expected restart note: {res.stdout}"
    assert "plain herdr update in v0.9.5 keeps endpoint-generation-1 server sessions running" in res.stdout, \
        f"expected v0.9.5 update note: {res.stdout}"

    # 4. Configured as backend: session-pty-recorder contract mismatch -> FAIL
    cfg_herdr["session_herdr_command"] = "herdr"
    (repo / ".nogging/config.json").write_text(json.dumps(cfg_herdr))
    recorder = repo / "scripts/session-pty-recorder"
    orig_recorder_bytes = recorder.read_bytes()
    # Replace recorder with incompatible contract
    recorder.write_text("#!/usr/bin/env python3\nimport json, sys\n"
                        "print(json.dumps({'version': 2}))\n")
    recorder.chmod(0o755)

    res = run_doctor()
    assert res.returncode == 1, f"doctor should have failed with recorder contract mismatch: {res.stdout}"
    assert any("FAIL" in line and "session-pty-recorder" in line for line in res.stdout.splitlines()), \
        f"expected FAIL mentioning recorder: {res.stdout}"
    recorder.write_bytes(orig_recorder_bytes)
    recorder.chmod(0o755)

    # 5. Configured as backend: herdr version outside 0.9.x -> WARN (not FAIL)
    bin_dir = temp_dir / "bin"
    bin_dir.mkdir()
    fake_herdr_v1 = bin_dir / "herdr"
    fake_herdr_v1.write_text("#!/usr/bin/env bash\n"
                             "if [[ \"$*\" == *\"--version\"* ]]; then echo 'herdr 0.10.0'; exit 0; fi\n"
                             f"exec {stub_bin} \"$@\"\n")
    fake_herdr_v1.chmod(0o755)

    res = run_doctor(extra_env={"PATH": f"{bin_dir}:{env['PATH']}"})
    assert res.returncode == 0, f"doctor should not fail on version warning: {res.stdout}\n{res.stderr}"
    assert any("WARN" in line and "0.10.0" in line and "0.9.x" in line for line in res.stdout.splitlines()), \
        f"expected WARN for version outside 0.9.x: {res.stdout}"
    assert any("OK" in line and "herdr binary" in line for line in res.stdout.splitlines())
    assert any("OK" in line and "session-pty-recorder helper contract" in line for line in res.stdout.splitlines())
    assert "server restart ends every nogging herdr session" in res.stdout.lower()

    # 6. Configured as backend: valid version 0.9.5 and server reachable -> OK + reachability NOTE
    res = run_doctor()
    assert res.returncode == 0, f"doctor failed on valid herdr: {res.stdout}\n{res.stderr}"
    assert any("OK" in line and "herdr binary" in line for line in res.stdout.splitlines())
    assert any("OK" in line and "session-pty-recorder helper contract" in line for line in res.stdout.splitlines())
    assert not any("WARN" in line and "herdr" in line.lower() for line in res.stdout.splitlines())
    assert any("NOTE" in line and "reachable (running)" in line for line in res.stdout.splitlines()), \
        f"expected reachable running note: {res.stdout}"
    assert "server restart ends every nogging herdr session" in res.stdout.lower()

    # 7. Configured as backend: server not running -> NOTE (starts on demand, not FAIL)
    (herdr_stub_dir / "server_down").touch()
    res = run_doctor()
    assert res.returncode == 0, f"doctor should not fail when server not running: {res.stdout}"
    assert any("NOTE" in line and "not running (starts on demand)" in line for line in res.stdout.splitlines()), \
        f"expected not running note: {res.stdout}"
    (herdr_stub_dir / "server_down").unlink()

    # 8. Records-only mode: session_backend is tmux, but non-retired herdr record exists
    cfg_tmux = base_config.copy()
    cfg_tmux["session_backend"] = "tmux"
    (repo / ".nogging/config.json").write_text(json.dumps(cfg_tmux))
    active_rec = {
        "name": "live-herdr",
        "backend": "herdr",
        "bead_id": "SPEC-1",
        "state": "running"
    }
    (sessions_dir / "live-herdr.json").write_text(json.dumps(active_rec))

    # 8a: Missing binary -> WARN, NOT FAIL
    cfg_tmux["session_herdr_command"] = "/missing/nonexistent/herdr"
    (repo / ".nogging/config.json").write_text(json.dumps(cfg_tmux))
    res = run_doctor()
    assert res.returncode == 0, f"records-only mode must not fail on missing binary:\nSTDOUT:\n{res.stdout}\nSTDERR:\n{res.stderr}"
    assert not any("FAIL" in line and "herdr" in line.lower() for line in res.stdout.splitlines()), \
        f"records-only mode must have no FAIL for herdr: {res.stdout}"
    assert any("WARN" in line and "/missing/nonexistent/herdr" in line for line in res.stdout.splitlines()), \
        f"expected WARN for missing binary in records-only mode: {res.stdout}"
    assert any("NOTE" in line and "herdr records exist" in line for line in res.stdout.splitlines()), \
        f"expected records-only note: {res.stdout}"
    assert "server restart ends every nogging herdr session" in res.stdout.lower()

    # 8b: Recorder broken -> WARN, NOT FAIL
    cfg_tmux["session_herdr_command"] = "herdr"
    (repo / ".nogging/config.json").write_text(json.dumps(cfg_tmux))
    recorder.write_text("#!/usr/bin/env python3\nimport json, sys\n"
                        "print(json.dumps({'version': 2}))\n")
    recorder.chmod(0o755)
    res = run_doctor()
    assert res.returncode == 0, f"records-only mode must not fail on broken recorder: {res.stdout}"
    assert not any("FAIL" in line and "session-pty-recorder" in line for line in res.stdout.splitlines()), \
        f"records-only mode must not FAIL for recorder: {res.stdout}"
    assert any("WARN" in line and "session-pty-recorder" in line for line in res.stdout.splitlines()), \
        f"expected WARN for recorder in records-only mode: {res.stdout}"
    recorder.write_bytes(orig_recorder_bytes)
    recorder.chmod(0o755)

    # 8c: All valid in records-only mode -> NO FAIL, notes shown
    res = run_doctor()
    assert res.returncode == 0, f"doctor failed: {res.stdout}"
    assert not any("FAIL" in line and "herdr" in line.lower() for line in res.stdout.splitlines())
    assert not any("WARN" in line and "herdr" in line.lower() for line in res.stdout.splitlines())
    assert any("NOTE" in line and "herdr records exist" in line for line in res.stdout.splitlines())
    assert any("NOTE" in line and "reachable (running)" in line for line in res.stdout.splitlines())
    assert "server restart ends every nogging herdr session" in res.stdout.lower()

print("doctor-herdr tests (unused, FAIL, WARN, restart NOTE, records-only): ok")
PY
