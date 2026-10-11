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
        for k in list(env.keys()):
            if k.startswith("NOGG_") or k == "NOGGING_ROOT":
                env.pop(k, None)
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
        bd_script = '''#!/bin/sh
case "$1" in
  show)
    case "$2" in
      SPEC-blocked) echo '[{"id":"SPEC-blocked","labels":["openspec:change:test-change","openspec:task:TASK-BLOCKED"]}]' ;;
      SPEC-ready)   echo '[{"id":"SPEC-ready","labels":["openspec:change:test-change","openspec:task:TASK-READY"]}]' ;;
      *)            echo '[{"id":"'"$2"'","labels":["openspec:change:test-change","openspec:task:TASK-TEST"]}]' ;;
    esac ;;
  dep)
    case "$3" in
      SPEC-blocked) echo '[{"id":"SPEC-blocker","status":"open"}]' ;;
      SPEC-ready)   echo '[{"id":"SPEC-blocker","status":"closed"}]' ;;
      *)            echo '[]' ;;
    esac ;;
  list) echo '[]' ;;
  *) exit 1 ;;
esac
'''
        bd.write_text(bd_script)
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
            # #37: Blocked Bead launch is refused before tmux session or record creation
            res_blocked = subprocess.run([str(nogg), "session", "launch", "--role", "lead",
                                          "--bead", "SPEC-blocked", "--agent", "claude"],
                                         cwd=consumer, env=env, text=True, capture_output=True, timeout=10)
            assert res_blocked.returncode != 0
            assert "SPEC-blocked has an unmet dependency on SPEC-blocker" in (res_blocked.stdout + res_blocked.stderr)
            assert not any("spec-blocked" in p.name.lower() for p in (consumer / ".nogging/state/sessions").glob("*.json"))

            # #37 & #39: Ready Bead launch with --kickoff succeeds and suppresses missing-kickoff hint
            res_ready = subprocess.run([str(nogg), "session", "launch", "--role", "lead",
                                        "--bead", "SPEC-ready", "--agent", "claude", "--kickoff"],
                                       cwd=consumer, env=env, text=True, capture_output=True, timeout=10)
            assert res_ready.returncode == 0, res_ready.stderr
            assert "this session will not act until you send it a first message" not in res_ready.stdout
            ready_recs = [json.loads(p.read_text()) for p in (consumer / ".nogging/state/sessions").glob("*.json")
                          if not p.name.endswith(".settings.json") and "spec-ready" in p.name.lower()
                          and json.loads(p.read_text()).get("state") == "running"]
            assert len(ready_recs) == 1
            subprocess.run([str(nogg), "session", "stop", ready_recs[0]["name"]],
                           cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True, timeout=10)
            subprocess.run([str(nogg), "session", "cleanup", ready_recs[0]["name"]],
                           cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True, timeout=10)

            # #40 & #38: Full-access launch verifies bypassPermissions, skipDangerousMode disclaimer,
            # deny preservation, and suppresses restricted/manual-mode warning
            res_full = subprocess.run([str(nogg), "session", "launch", "--role", "lead",
                                       "--bead", "SPEC-ready", "--agent", "claude", "--full-access"],
                                      cwd=consumer, env=env, text=True, capture_output=True, timeout=10)
            assert res_full.returncode == 0, res_full.stderr
            assert "launched in restricted/manual mode" not in res_full.stdout
            full_recs = [json.loads(p.read_text()) for p in (consumer / ".nogging/state/sessions").glob("*.json")
                         if not p.name.endswith(".settings.json") and "spec-ready" in p.name.lower()
                         and json.loads(p.read_text()).get("state") == "running"]
            assert len(full_recs) == 1
            full_rec = full_recs[0]
            assert full_rec["profile"] == "trusted"
            settings = json.loads(pathlib.Path(full_rec["effective_settings_path"]).read_text())
            assert settings["permissions"]["defaultMode"] == "bypassPermissions"
            assert settings.get("skipDangerousModePermissionPrompt") is True
            deny = settings["permissions"].get("deny", [])
            assert any("sudo" in d for d in deny)
            assert any("rm -rf" in d for d in deny)
            subprocess.run([str(nogg), "session", "stop", full_rec["name"]],
                           cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True, timeout=10)
            subprocess.run([str(nogg), "session", "cleanup", full_rec["name"]],
                           cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True, timeout=10)

            # #37 & #40: Orchestrator launch is Bead-less, runs FULL-ACCESS with lifted floor
            res_orc = subprocess.run([str(nogg), "session", "launch", "--role", "orchestrator",
                                      "--profile", "orchestrator", "--agent", "claude"],
                                     cwd=consumer, env=env, text=True, capture_output=True, timeout=10)
            assert res_orc.returncode == 0, res_orc.stderr
            assert "launched in restricted/manual mode" not in res_orc.stdout
            orc_recs = [json.loads(p.read_text()) for p in (consumer / ".nogging/state/sessions").glob("nogg-orchestrator-*.json")
                        if not p.name.endswith(".settings.json")]
            assert len(orc_recs) == 1
            orc_rec = orc_recs[0]
            assert orc_rec["role"] == "orchestrator"
            assert orc_rec.get("floor_lifted") is True
            orc_settings = json.loads(pathlib.Path(orc_rec["effective_settings_path"]).read_text())
            assert orc_settings["permissions"]["defaultMode"] == "bypassPermissions"
            assert orc_settings.get("skipDangerousModePermissionPrompt") is True
            orc_deny = orc_settings["permissions"].get("deny", [])
            assert not any("sudo" in d for d in orc_deny)
            subprocess.run([str(nogg), "session", "stop", orc_rec["name"]],
                           cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True, timeout=10)
            subprocess.run([str(nogg), "session", "cleanup", orc_rec["name"]],
                           cwd=consumer, env=env, stdout=subprocess.DEVNULL, check=True, timeout=10)

            for agent in ("claude", "codex", "pi"):
                result = subprocess.run([str(nogg), "session", "launch", "--role", "lead",
                                         "--bead", "SPEC-packed", "--agent", agent],
                                        cwd=consumer, env=env, text=True, capture_output=True, timeout=10)
                assert result.returncode == 0, result.stderr
                # #38 & #39: bare lead launch emits restricted/manual mode warning and explicit kickoff hint
                assert "launched in restricted/manual mode" in result.stdout
                assert "this session will not act until you send it a first message" in result.stdout
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
                active = [record for record in records if record["agent"] == agent and record["state"] == "running"]
                assert len(active) == 1 and active[0]["state"] == "running"
                record = active[0]
                assert pathlib.Path(record["log_path"]).is_file()
                # #39: explicit kickoff on active session
                kick = subprocess.run([str(nogg), "session", "kickoff", record["name"]],
                                      cwd=consumer, env=env, text=True, capture_output=True, timeout=10)
                assert kick.returncode == 0, kick.stderr
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
