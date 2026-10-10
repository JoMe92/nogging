#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v tmux >/dev/null; then
  printf 'SKIP: packed live-pane launch regression (tmux unavailable)\n'
  exit 0
fi
python3 - "$root" <<'PY'
import datetime, json, os, pathlib, shutil, socket, subprocess, sys, tarfile, tempfile, time, uuid

# This test asserts real read-only mounts, so never substitute a fake fence.
# Match the dedicated sandbox test on hosts that prohibit user namespaces.
probe = subprocess.run(['unshare', '--user', '--map-root-user', '--mount', 'true'],
                       capture_output=True)
if probe.returncode:
    print('SKIP: packed live fence launch (host denies Linux user/mount namespaces; production execution must refuse)')
    sys.exit(0)
source = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="nogg packed launch ") as directory:
    scratch = pathlib.Path(directory)
    packed = json.loads(subprocess.check_output(
        ["npm", "pack", "--ignore-scripts", "--json", "--pack-destination", str(scratch)],
        cwd=source, text=True))[0]
    inventory = {entry["path"] for entry in packed["files"]}
    for name in ("nogg", "session-launch", "session-log-writer", "openspec-sandbox"):
        assert "scripts/" + name in inventory
    with tarfile.open(scratch / packed["filename"]) as archive:
        archive.extractall(scratch, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
    package = scratch / "package"
    for scenario in ("fresh", "old-install-update"):
        consumer = scratch / (scenario + " with spaces")
        consumer.mkdir()
        subprocess.run(["git", "init", "-q", str(consumer)], check=True)
        env = os.environ.copy()
        env.pop("NOGGING_ROOT", None)
        env.pop("NOGG_SESSION_NAME", None)
        install = ["node", str(package / "bin/cli.js")]
        flags = ["--no-beads", "--no-hooks", "--no-systemd"]
        subprocess.run(install + ["init"] + flags, cwd=consumer, env=env,
                       stdout=subprocess.DEVNULL, check=True)
        if scenario == "old-install-update":
            (consumer / "scripts/session-launch").unlink()
            writer = consumer / "scripts/session-log-writer"
            writer.write_text("#!/bin/sh\necho obsolete\n")
            writer.chmod(0o644)
            subprocess.run(install + ["update"] + flags, cwd=consumer, env=env,
                           stdout=subprocess.DEVNULL, check=True)
        for name in ("nogg", "session-launch", "session-log-writer", "openspec-sandbox"):
            installed = consumer / "scripts" / name
            assert installed.read_bytes() == (package / "scripts" / name).read_bytes()
            assert os.access(installed, os.X_OK)
        binaries, arguments = consumer / "stub-bin", consumer / "received-args"
        binaries.mkdir()
        arguments.mkdir()
        bd = binaries / "bd"
        bd.write_text('#!/bin/sh\ncase "$1" in show) echo \'[{"id":"SPEC-packed"}]\';; dep|list) echo "[]";; *) exit 1;; esac\n')
        bd.chmod(0o755)
        runtime = '''#!/usr/bin/env python3
import json, os, pathlib, sys, time
if "--help" in sys.argv:
    print("stub runtime")
    sys.exit(0)
target = pathlib.Path(os.environ["NOGG_TEST_ARGS_DIR"]) / pathlib.Path(sys.argv[0]).name
assert os.environ.get("NOGG_OPENSPEC_FENCED") == "1", "runtime lacks filesystem fence"
for action in [lambda: (pathlib.Path.cwd()/"openspec/forbidden.md").write_text("bad"),
               lambda: (pathlib.Path.cwd()/"openspec/config.yaml").unlink()]:
    try: action()
    except PermissionError: pass
    except OSError as exc:
        assert exc.errno == 30, exc
    else: raise AssertionError("runtime persisted OpenSpec edit")
target.write_text(json.dumps(sys.argv[1:]))
print("stub ready", flush=True)
while True:
    time.sleep(0.1)
'''
        for agent in ("claude", "codex", "pi"):
            binary = binaries / agent
            binary.write_text(runtime)
            binary.chmod(0o755)
        config_path = consumer / ".nogging/config.json"
        config = json.loads(config_path.read_text())
        sock = "nogg-packed-test-" + uuid.uuid4().hex
        config.update(session_tmux_socket=sock, session_stop_grace_seconds=0.1)
        config_path.write_text(json.dumps(config))
        env.update(NOGGING_ROOT=str(consumer), NOGG_TEST_ARGS_DIR=str(arguments),
                   PATH=str(binaries) + os.pathsep + env["PATH"])
        nogg = consumer / "scripts/nogg"
        locks = consumer / ".nogging/locks"
        (locks / "openspec.readonly").unlink(missing_ok=True)
        planning_lock = locks / "planning.lock"
        planning_lock.write_text(json.dumps({"pid": os.getpid(), "host": socket.gethostname(),
            "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}))
        owner_lock_bytes = planning_lock.read_bytes()
        try:
            for agent in ("claude", "codex", "pi"):
                result = subprocess.run([str(nogg), "session", "launch", "--role", "lead",
                                         "--bead", "SPEC-packed", "--agent", agent],
                                        cwd=consumer, env=env, text=True, capture_output=True, timeout=10)
                assert result.returncode == 0, result.stderr
                deadline = time.monotonic() + 5
                received = arguments / agent
                while not received.exists():
                    assert time.monotonic() < deadline, f"{scenario}: {agent} never started"
                    time.sleep(0.02)
                argv = json.loads(received.read_text())
                assert argv
                if agent == "claude":
                    assert "--session-id" in argv and "--settings" in argv
                elif agent == "codex":
                    assert "--sandbox" in argv and "--ask-for-approval" in argv
                records = [json.loads(p.read_text()) for p in
                           (consumer / ".nogging/state/sessions").glob("*.json")
                           if not p.name.endswith(".settings.json")]
                active = [record for record in records if record["agent"] == agent]
                assert len(active) == 1 and active[0]["state"] == "running"
                record = active[0]
                assert pathlib.Path(record["log_path"]).is_file()
                subprocess.run([str(nogg), "session", "stop", record["name"]],
                               cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True, timeout=10)
                subprocess.run([str(nogg), "session", "cleanup", record["name"]],
                               cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True, timeout=10)
                assert planning_lock.read_bytes() == owner_lock_bytes
                assert not (locks / "openspec.readonly").exists(), "execution cleanup closed another planner boundary"
                print(f"packed {scenario}: {agent} launch/fence during planning/argv/log/stop/cleanup passed")
        finally:
            subprocess.run(["tmux", "-L", sock, "kill-server"], capture_output=True)
PY
