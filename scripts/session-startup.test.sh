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
with tempfile.TemporaryDirectory(prefix="nogg.", dir="/tmp") as directory:
    root = pathlib.Path(directory)
    for name in (".nogging", "scripts", "bin", "openspec"):
        (root / name).mkdir()
    for name in ("launch-profiles", "launch-prompts"):
        shutil.copytree(source / ".nogging" / name, root / ".nogging" / name)
    subprocess.run(["bash", str(source / "scripts/lib/test-fixture-config.sh"),
                    str(source / ".nogging/config.json"), str(root / ".nogging/config.json")], check=True)
    config = json.loads((root / ".nogging/config.json").read_text())
    sock = "nogg-startup-test-" + uuid.uuid4().hex
    tmux_tmpdir = root / "tmux"
    tmux_tmpdir.mkdir()
    socket_path = tmux_tmpdir / f"tmux-{os.getuid()}" / sock
    assert len(str(socket_path).encode()) < 108, socket_path
    config["session_tmux_socket"] = sock
    config["beads_command"] = str(root / "bin/bd")
    config["usage_gate"] = {"enabled": False}
    (root / ".nogging/config.json").write_text(json.dumps(config))
    for name in ("nogg", "nogg_usage.py", "session-launch", "session-log-writer", "openspec-sandbox"):
        shutil.copy2(source / "scripts" / name, root / "scripts" / name)
    shutil.copytree(source / "scripts/lib", root / "scripts/lib")
    # Exercise real tmux/startup logging independently of host mount support.
    # Preserve helper contract checks; dedicated fence tests use the real helper.
    boundary = root / "scripts/openspec-sandbox"
    boundary.rename(root / "scripts/openspec-sandbox-real")
    boundary.write_text('''#!/bin/sh
if [ "${1:-}" = --contract ]; then
  exec "$(dirname "$0")/openspec-sandbox-real" --contract
fi
NOGG_OPENSPEC_FENCED=1 exec "$@"
''')
    boundary.chmod(0o755)
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    fixtures = {
        "bd": '#!/bin/sh\ncase "$1" in show) echo \'[{"id":"SPEC-live"}]\';; dep) echo "[]";; esac\n',
        "claude": '#!/bin/sh\necho "runtime-live: unknown option --session-id; token=$NOGG_TEST_API_TOKEN" >&2\nexit 64\n',
    }
    for name, body in fixtures.items():
        path = root / "bin" / name
        path.write_text(body)
        path.chmod(0o755)
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("NOGG_", "HERDR_")) or key in {"TMUX", "TMUX_TMPDIR"}:
            env.pop(key)
    env.update(NOGGING_ROOT=str(root), PATH=str(root / "bin") + os.pathsep + env["PATH"],
               NOGG_TEST_API_TOKEN="private-startup-fixture", TMUX_TMPDIR=str(tmux_tmpdir))
    try:
        # Reproduce a fenced caller on an empty, test-owned tmux socket. The
        # server-start guard must refuse before creating session artifacts.
        fenced_env = dict(env, NOGG_OPENSPEC_FENCED="1")
        refused = subprocess.run([str(root / "scripts/nogg"), "session", "launch",
                                  "--role", "lead", "--bead", "SPEC-live"],
                                 env=fenced_env, text=True, capture_output=True, timeout=10)
        assert refused.returncode != 0, (refused.stdout, refused.stderr)
        assert "sandboxed session cannot start it" in refused.stderr, refused.stderr
        session_dir = root / ".nogging/state/sessions"
        assert not (list(session_dir.glob("*")) if session_dir.exists() else []), \
            list(session_dir.glob("*")) if session_dir.exists() else []
        assert not socket_path.exists(), "fenced launch created its tmux server socket"

        # This suite exercises runtime startup failure after backend prepare.
        # Seed the shared server from the host before the fenced launch.
        subprocess.run(["tmux", "-L", sock, "new-session", "-d", "-s", "host-anchor"],
                       env=env, check=True, capture_output=True)
        result = subprocess.run([str(root / "scripts/nogg"), "session", "launch",
                                 "--role", "lead", "--bead", "SPEC-live"],
                                env=env, text=True, capture_output=True, timeout=10)
        sessions = root / ".nogging/state/sessions"
        deadline = time.monotonic() + 5
        while True:
            records = [p for p in sessions.glob("*.json") if not p.name.endswith(".settings.json")]
            assert len(records) == 1, (result.stdout, result.stderr, list(sessions.glob("*")))
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
