#!/usr/bin/env bash
# TASK-HSS-001: fenced tmux calls never start a server.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; use_agent_stubs
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 - "$here" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest.mock import patch

scripts = Path(sys.argv[1])
sys.dont_write_bytecode = True
for key in list(os.environ):
    if key.startswith(("NOGG_", "HERDR_")) or key in {"TMUX", "TMUX_TMPDIR"}:
        os.environ.pop(key)
sys.path.insert(0, str(scripts / "lib"))
from session_backend import BackendError, LogCapture
from session_backend_tmux import TmuxBackend

with tempfile.TemporaryDirectory(prefix="nogg.", dir="/tmp") as temp:
    root = Path(temp)
    socket_dir = root / "socket"
    socket_dir.mkdir()
    sock = str(socket_dir / "tmux.sock")
    assert len(sock.encode()) < 108, sock
    calls_path = root / "calls.jsonl"
    server = root / "server-running"
    stub = root / "tmux"
    stub.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['TMUX_STUB_CALLS'], 'a') as stream:
    stream.write(json.dumps(args) + '\\n')
if '-N' in args:
    command = args[args.index('-N') + 1:]
else:
    command = args[args.index('-L') + 2:]
state = Path(os.environ['TMUX_STUB_SERVER'])
if command and command[0] == 'list-sessions':
    if state.exists(): print('existing')
    else: sys.exit(1)
elif command and command[0] == 'new-session':
    if '-N' in args or not state.exists(): sys.exit(1)
elif command and command[0] == 'has-session':
    if not state.exists(): sys.exit(1)
""")
    stub.chmod(0o755)
    env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
               TMUX_STUB_CALLS=str(calls_path), TMUX_STUB_SERVER=str(server))
    def run(*argv, check=True):
        return subprocess.run(argv, text=True, capture_output=True, env=env, check=check)

    backend = TmuxBackend({"session_tmux_command": str(stub), "session_tmux_socket": sock}, run)
    log = LogCapture(str(root / "session.log"), str(scripts / "session-log-writer"))
    with patch.dict(os.environ, NOGG_OPENSPEC_FENCED="1"):
        # An absent host server is refused during prepare, before any session artifacts.
        try:
            backend.prepare("sf-test", str(root))
        except BackendError as exc:
            assert "sandboxed session cannot start it" in str(exc)
            assert "unsandboxed shell" in str(exc)
        else:
            raise AssertionError("fenced launch passed prepare without a server")
        assert not (root / "session.log").exists()
        assert not (root / "record.json").exists()

        # A server that vanishes after preflight cannot be restarted by new-session.
        server.touch()
        assert backend.prepare("sf-race", str(root)) == {"name": "sf-race", "socket": sock}
        assert backend.attach_argv("sf-race")[3] == "-N"
        assert backend.liveness_probe("sf-race")["argv"][3] == "-N"
        server.unlink()
        try:
            backend.start("sf-race", str(root), {}, ["agent"], log)
        except subprocess.CalledProcessError:
            pass
        else:
            raise AssertionError("raced new-session unexpectedly started a server")

    # Every backend command while fenced has global -N before the tmux command.
    calls = [json.loads(line) for line in calls_path.read_text().splitlines()]
    assert calls and all("-N" in argv for argv in calls), calls
    assert all(argv.index("-N") < argv.index("list-sessions") for argv in calls[:2])

    # Unfenced argv remains byte-identical to the legacy command shape.
    with patch.dict(os.environ):
        os.environ.pop("NOGG_OPENSPEC_FENCED", None)
        backend.command("list-sessions", check=False)
    last = json.loads(calls_path.read_text().splitlines()[-1])
    assert last == ["-L", sock, "list-sessions"]
    assert backend.attach_argv("sf-test") == [str(stub), "-L", sock, "attach", "-t", "sf-test"]
    assert backend.liveness_probe("sf-test")["argv"] == [
        str(stub), "-L", sock, "has-session", "-t", "sf-test"]

    # Exercise the public launch lifecycle: a race after prepare leaves a terminal failed record.
    launch_root = root / "launch"
    (launch_root / ".nogging").mkdir(parents=True)
    (launch_root / "scripts/lib").mkdir(parents=True)
    (launch_root / "bin").mkdir()
    for name in ("nogg", "nogg_usage.py", "session-launch", "session-log-writer", "openspec-sandbox"):
        shutil.copy2(scripts / name, launch_root / "scripts" / name)
    for path in (scripts / "lib").iterdir():
        if path.is_file(): shutil.copy2(path, launch_root / "scripts/lib" / path.name)
    shutil.copy2(scripts.parent / ".nogging/config.json", launch_root / ".nogging/config.json")
    for name in ("launch-profiles", "launch-prompts"):
        shutil.copytree(scripts.parent / ".nogging" / name, launch_root / ".nogging" / name)
    launch_tmux = launch_root / "bin/tmux"
    launch_tmux.write_text("""#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
command = args[args.index('-N') + 1:] if '-N' in args else args[args.index('-L') + 2:]
server = Path(os.environ['TMUX_STUB_SERVER'])
if command[0] == 'list-sessions':
    if server.exists(): print('existing')
    else: sys.exit(1)
elif command[0] == 'has-session':
    sys.exit(1)
elif command[0] == 'new-session':
    server.unlink(missing_ok=True)
    sys.exit(1)
""")
    launch_tmux.chmod(0o755)
    bd = launch_root / "bin/bd"
    bd.write_text("""#!/bin/sh
case "$1" in
  show) echo '[{"id":"SPEC-test","labels":["openspec:change:harden-session-supervision","openspec:task:TASK-HSS-001"]}]' ;;
  dep) echo '[]' ;;
  list) echo '[]' ;;
  *) exit 1 ;;
esac
""")
    bd.chmod(0o755)
    launch_config = json.loads((launch_root / ".nogging/config.json").read_text())
    launch_config.update(session_tmux_command=str(launch_tmux), session_tmux_socket=sock,
                         beads_command=str(bd), usage_gate={"enabled": False})
    (launch_root / ".nogging/config.json").write_text(json.dumps(launch_config))
    server.touch()
    launch_env = dict(os.environ, NOGGING_ROOT=str(launch_root), NOGG_OPENSPEC_FENCED="1",
                      TMUX_STUB_SERVER=str(server), PATH=str(launch_root / "bin") + os.pathsep + os.environ["PATH"])
    launched = subprocess.run([str(launch_root / "scripts/nogg"), "session", "launch",
                               "--role", "lead", "--bead", "SPEC-test", "--agent", "claude"],
                              env=launch_env, text=True, capture_output=True, timeout=15)
    assert launched.returncode != 0, (launched.stdout, launched.stderr)
    records = [p for p in (launch_root / ".nogging/state/sessions").glob("*.json")
               if not p.name.endswith(".settings.json")]
    assert len(records) == 1, records
    record = json.loads(records[0].read_text())
    assert record["state"] == "failed", record
    assert "launch failed" in record["exit_reason"], record
    assert not server.exists(), "raced launch started a tmux server in the fenced caller"

print("ok - fenced refusal, failed launch race, and unchanged unfenced argv")
PY
