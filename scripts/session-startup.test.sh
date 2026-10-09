#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v tmux >/dev/null; then
  printf 'SKIP: real tmux startup regression (tmux unavailable)\n'
  exit 0
fi
python3 - "$root" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile, time, uuid

source = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="nogg startup ") as directory:
    root = pathlib.Path(directory)
    for name in (".nogging", "scripts", "bin"):
        (root / name).mkdir()
    for name in ("launch-profiles", "launch-prompts"):
        shutil.copytree(source / ".nogging" / name, root / ".nogging" / name)
    config = json.loads((source / ".nogging/config.json").read_text())
    sock = "nogg-startup-test-" + uuid.uuid4().hex
    config["session_tmux_socket"] = sock
    config["beads_command"] = str(root / "bin/bd")
    (root / ".nogging/config.json").write_text(json.dumps(config))
    for name in ("nogg", "session-launch", "session-log-writer"):
        shutil.copy2(source / "scripts" / name, root / "scripts" / name)
    fixtures = {
        "bd": '#!/bin/sh\ncase "$1" in show) echo \'[{"id":"SPEC-live"}]\';; dep) echo "[]";; esac\n',
        "claude": '#!/bin/sh\necho "runtime-live: unknown option --session-id; token=$NOGG_TEST_API_TOKEN" >&2\nexit 64\n',
    }
    for name, body in fixtures.items():
        path = root / "bin" / name
        path.write_text(body)
        path.chmod(0o755)
    env = os.environ.copy()
    env.update(NOGGING_ROOT=str(root), PATH=str(root / "bin") + os.pathsep + env["PATH"],
               NOGG_TEST_API_TOKEN="private-startup-fixture")
    try:
        result = subprocess.run([str(root / "scripts/nogg"), "session", "launch",
                                 "--role", "lead", "--bead", "SPEC-live"],
                                env=env, text=True, capture_output=True, timeout=10)
        sessions = root / ".nogging/state/sessions"
        deadline = time.monotonic() + 5
        while True:
            records = [p for p in sessions.glob("*.json") if not p.name.endswith(".settings.json")]
            assert len(records) == 1
            try:
                record = json.loads(records[0].read_text())
            except json.JSONDecodeError:
                record = {}
            if record.get("state") == "failed":
                break
            assert time.monotonic() < deadline, "immediate runtime failure was not recorded"
            time.sleep(0.02)
        assert "runtime-live: unknown option --session-id" in record["exit_reason"]
        assert "runtime-live: unknown option --session-id" in pathlib.Path(record["log_path"]).read_text()
        # A delayed launcher must never resurrect the failed child.
        code = ('from importlib.machinery import SourceFileLoader; import json,sys; '
                'm=SourceFileLoader("lifecycle",sys.argv[1]).load_module(); '
                'p=m.Path(sys.argv[2]); r=json.loads(p.read_text()); '
                'm.transition(p,r,"running"); assert r["state"] == "failed"')
        subprocess.run([sys.executable, "-c", code, str(root / "scripts/nogg"), str(records[0])],
                       env=env, check=True)
        artifacts = result.stdout + result.stderr + "".join(
            p.read_text() for p in sessions.iterdir() if p.is_file())
        assert "private-startup-fixture" not in artifacts
    finally:
        subprocess.run(["tmux", "-L", sock, "kill-server"], capture_output=True)
print("real tmux immediate startup failure and terminal-state preservation: ok")
PY
