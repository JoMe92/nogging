#!/usr/bin/env bash
# End-to-end herdr session lifecycle through scripts/nogg (TASK-HDR-011).
set -euo pipefail

# Test fixtures must not inherit the supervised agent's private session context.
while IFS='=' read -r name _; do
  case "$name" in NOGG_*|HERDR_*|TMUX|NOGGING_ROOT) unset "$name" ;; esac
done < <(env)

source_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$source_root" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

source = Path(sys.argv[1])
assert not any(key.startswith("NOGG_") or key == "NOGGING_ROOT" for key in os.environ), \
    "supervised-session environment leaked into the test fixture"

class Scratch:
    def __enter__(self):
        self.root = Path(tempfile.mkdtemp(prefix="h", dir="/tmp"))
        return self.root
    def __exit__(self, *_exc):
        env = os.environ.copy()
        env.update({"NOGGING_ROOT": str(self.root), "HERDR_STUB_DIR": str(self.root / "s"),
                    "TMUX_STUB_DIR": str(self.root / "tmux"),
                    "PATH": str(self.root / "b") + os.pathsep + str(source / "scripts/fixtures/herdr/bin")
                            + os.pathsep + env["PATH"]})
        sessions = self.root / ".nogging/state/sessions"
        if sessions.is_dir() and (self.root / ".nogging/config.json").is_file():
            for path in sessions.glob("*.json"):
                try: record = json.loads(path.read_text())
                except (OSError, ValueError): continue
                if record.get("name") and record.get("state") in ("starting", "running", "idle"):
                    subprocess.run([str(source / "scripts/nogg"), "session", "stop", record["name"]],
                                   env=env, text=True, capture_output=True, timeout=10)
        subprocess.run([str(source / "scripts/fixtures/herdr/bin/herdr"), "--session", "hdr-e2e",
                        "server", "stop"], env=env, text=True, capture_output=True, timeout=5)
        shutil.rmtree(self.root, ignore_errors=True)

def run(argv, *, env=None, cwd=None, check=True, timeout=20):
    result = subprocess.run(argv, cwd=cwd, env=env, text=True, capture_output=True,
                            timeout=timeout)
    if check and result.returncode:
        raise AssertionError(f"{argv!r} failed ({result.returncode})\n{result.stdout}\n{result.stderr}")
    return result

with Scratch() as root:
    stub = root / "s"
    bins = root / "b"
    stub.mkdir()
    bins.mkdir()
    (root / ".nogging/locks").mkdir(parents=True)
    (root / ".nogging/locks/openspec.readonly").touch()
    (root / "openspec").mkdir()
    (root / "scripts").mkdir()
    for helper in ("nogg", "nogg_usage.py", "session-launch", "session-log-writer",
                   "session-pty-recorder"):
        shutil.copy2(source / "scripts" / helper, root / "scripts" / helper)
    (root / "scripts/lib").symlink_to(source / "scripts/lib", target_is_directory=True)
    # This suite exercises herdr lifecycle, not Linux mount support. Isolate
    # the fence just as session-startup.test.sh does, keeping contract checks
    # real and every herdr assertion active on hosts that deny user namespaces.
    # openspec-sandbox.test.sh and packed-session-launch.test.sh test the fence.
    boundary = root / "scripts/openspec-sandbox"
    boundary.write_text("#!/bin/sh\n"
        'if [ "${1:-}" = --contract ]; then\n'
        "  exec " + shlex.quote(str(source / "scripts/openspec-sandbox")) + ' --contract\n'
        "fi\n"
        'NOGG_OPENSPEC_FENCED=1 exec "$@"\n')
    boundary.chmod(0o755)
    for name in ("launch-profiles", "launch-prompts"):
        shutil.copytree(source / ".nogging" / name, root / ".nogging" / name)
    subprocess.run(["git", "init", "-q", str(root)], check=True)

    cfg = json.loads((source / ".nogging/config.json").read_text())
    cfg.update({"session_backend": "herdr", "session_herdr_command": str(bins / "herdr"),
                "session_repository_root": str(root), "session_repository_slug": "hdr-e2e",
                "session_herdr_session": "hdr-e2e",
                "session_stop_grace_seconds": 0.05, "session_state_dir": ".nogging/state/sessions",
                "beads_command": str(bins / "bd"), "session_tmux_command": str(bins / "tmux")})
    (root / ".nogging/config.json").write_text(json.dumps(cfg))

    (bins / "herdr").write_text("#!/bin/sh\nexport HERDR_STUB_DIR=" + shlex.quote(str(stub)) +
        "\nexec " + shlex.quote(str(source / "scripts/fixtures/herdr/bin/herdr")) + " \"$@\"\n")
    (bins / "herdr").chmod(0o755)
    (bins / "bd").write_text("""#!/bin/sh
case "$1" in
  show) printf '[{"id":"%s","status":"in_progress","assignee":"test","labels":["openspec:change:add-herdr-session-backend","openspec:task:TASK-HDR-011"]}]\\n' "$2" ;;
  dep) echo '[]' ;;
  list) echo '[]' ;;
  *) echo "unexpected bd command: $*" >&2; exit 2 ;;
esac
""")
    (bins / "bd").chmod(0o755)
    # The runtime proves that Nogging wrote its record before executing argv.
    agent = bins / "claude"
    agent.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys, time
base = pathlib.Path(os.environ['NOGG_SESSION_ROOT']) / '.nogging/state/sessions'
record = json.loads((base / (os.environ['NOGG_SESSION_NAME'] + '.json')).read_text())
(base / (os.environ['NOGG_SESSION_NAME'] + '.observed.json')).write_text(
    json.dumps({'state': record['state'], 'argv': sys.argv[1:]}))
print('e2e-agent-started', flush=True)
while True: time.sleep(0.1)
""")
    agent.chmod(0o755)

    # A stateful tmux fixture is needed only for the pinned orchestrator case.
    (bins / "tmux").write_text("""#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -L ]] && shift 2
cmd="${1:-}"; shift || true
d="${TMUX_STUB_DIR:?}"; mkdir -p "$d"
printf '%s %s\\n' "$cmd" "$*" >>"$d/calls.log"
arg_after() { local f="$1"; shift; while (($#)); do [[ "$1" == "$f" ]] && { echo -n "$2"; return; }; shift; done; }
case "$cmd" in
  new-session) name="$(arg_after -s "$@")"; touch "$d/sess-$name" ;;
  has-session) name="$(arg_after -t "$@")"; [[ -f "$d/sess-$name" ]] ;;
  list-sessions) for f in "$d"/sess-*; do [[ -e "$f" ]] && echo "${f##*/sess-}"; done ;;
  send-keys) : ;;
  kill-session) name="$(arg_after -t "$@")"; rm -f "$d/sess-$name" ;;
  kill-server) rm -f "$d"/sess-* ;;
  pipe-pane|attach) : ;;
  *) : ;;
esac
""")
    (bins / "tmux").chmod(0o755)

    env = os.environ.copy()
    env.update({"NOGGING_ROOT": str(root), "PATH": str(bins) + os.pathsep +
                str(source / "scripts/fixtures/herdr/bin") + os.pathsep + env["PATH"],
                "HERDR_STUB_DIR": str(stub), "TMUX_STUB_DIR": str(root / "tmux"),
                "TEST_TOKEN": "private-e2e-token"})
    nogg = str(root / "scripts/nogg")
    control = str(source / "scripts/fixtures/herdr/bin/herdr-stub-control")
    sessions = root / ".nogging/state/sessions"

    # Stay within AF_UNIX sun_path even on CI's longer /tmp mount prefix.
    assert len(str(root / ".nogging/state/herdr/nogging.sock").encode()) < 100
    run([str(bins / "herdr"), "--session", "hdr-e2e", "server", "stop"], env=env)
    run([control, "opt-in-real-process"], env=env)
    launched = run([nogg, "session", "launch", "--role", "lead", "--bead", "SPEC-test",
                    "--agent", "claude", "--backend", "herdr", "--ignore-usage-gate"], env=env)
    herdr_records = [json.loads(p.read_text()) for p in sessions.glob("*.json")
                     if not p.name.endswith((".settings.json", ".observed.json"))
                     and json.loads(p.read_text()).get("backend") == "herdr"]
    assert len(herdr_records) == 1, launched.stdout
    live = herdr_records[0]
    name = live["name"]
    calls_path = stub / "calls.log"
    observed_path = sessions / (name + ".observed.json")
    for _ in range(100):
        if observed_path.exists(): break
        time.sleep(.05)
    assert observed_path.exists(), ("launch wrapper never exec'd the test agent; record=" +
        str(live) + "\nlog=" + Path(live["log_path"]).read_text(errors="replace") +
        "\ncalls=" + calls_path.read_text())
    observed = json.loads(observed_path.read_text())
    assert observed["state"] in ("starting", "running"), observed
    assert "--settings" in live["command"] and "--prompt" in live["command"]
    ref = live["backend_ref"]
    sock_path = Path(ref["socket_path"])
    assert len(str(sock_path).encode()) < 108, sock_path
    assert sock_path.exists() and stat.S_IMODE(sock_path.stat().st_mode) == 0o600
    calls = calls_path.read_text()
    assert calls.count("socket layout.apply ") == 1, calls
    assert "session-pty-recorder" in calls and "private-e2e-token" not in calls
    assert "--session hdr-e2e server" in calls

    # The record's liveness probe is the same backend-neutral probe bound to a reservation.
    sys.path.insert(0, str(source / "scripts/lib"))
    from session_backend_herdr import HerdrBackend
    backend_run = lambda *args, **kwargs: subprocess.run(args, text=True, capture_output=True, **kwargs)
    backend = HerdrBackend(cfg, backend_run)
    probe = backend.liveness_probe(ref)
    assert probe["backend"] == "herdr" and run(probe["argv"], env=env, check=False).returncode == 0

    # Unsafe socket mode refuses before metadata allocation.
    sock_path.chmod(0o660)
    before = len(list(sessions.glob("sf-lead-*.json")))
    refused = run([nogg, "session", "launch", "--role", "lead", "--bead", "SPEC-unsafe",
                   "--agent", "claude", "--backend", "herdr", "--ignore-usage-gate"],
                  env=env, check=False)
    assert refused.returncode and "0600" in refused.stderr, refused.stderr
    assert len(list(sessions.glob("sf-lead-*.json"))) == before
    sock_path.chmod(0o600)
    # The permission fault also changes ctime. Re-seal this test fixture's
    # receipt after deliberately restoring the socket for later launches.
    receipt_path = root / '.nogging/state/herdr/hdr-e2e/server.json'
    receipt = json.loads(receipt_path.read_text())
    receipt['socket'] = backend.verify_socket(str(sock_path))
    receipt_path.write_text(json.dumps(receipt))

    # Mixed listing, send, no-message nudge safety, explicit nudge and kickoff.
    state_file = stub / "state.json"
    state = json.loads(state_file.read_text())
    for pane in state.get("panes", {}).values():
        if pane.get("label") == name: pane["agent_status"] = "working"
    state_file.write_text(json.dumps(state))
    shutil.copyfile(source / "scripts/fixtures/herdr/spike/read/claude/idle-placeholder.ansi",
                    stub / ("pane-" + name + ".ansi"))
    sent = run([nogg, "session", "send", name, "e2e send", "--verify"], env=env)
    assert "sent to" in sent.stdout
    before_calls = calls_path.read_text().count("pane send-keys ")
    safe_nudge = run([nogg, "session", "nudge", name], env=env)
    assert "nothing was submitted" in safe_nudge.stdout
    assert calls_path.read_text().count("pane send-keys ") == before_calls
    run([nogg, "session", "nudge", name, "--message", "e2e explicit nudge"], env=env)
    # Kickoff waits for startup readiness: an idle runtime with a ready composer.
    def set_status(value):
        state = json.loads(state_file.read_text())
        for pane in state.get("panes", {}).values():
            if pane.get("label") == name: pane["agent_status"] = value
        state_file.write_text(json.dumps(state))
    set_status("idle")
    # Two readiness samples precede the kickoff, each several stub CLI round
    # trips; a loaded host needs more than the default 20 s for all of them.
    run([nogg, "session", "kickoff", name], env=env, timeout=90)
    set_status("working")
    # The orchestrator stays on tmux even with herdr configured as the default.
    orchestrator = run([nogg, "session", "launch", "--role", "orchestrator",
                        "--profile", "orchestrator", "--agent", "claude"], env=env)
    assert "launched nogg-orchestrator-" in orchestrator.stdout
    records = [json.loads(p.read_text()) for p in sessions.glob("nogg-orchestrator-*.json")
               if not p.name.endswith(".settings.json")]
    assert len(records) == 1 and records[0]["backend"] == "tmux", records
    listing = run([nogg, "session", "list"], env=env).stdout
    assert "AGENT_STATUS" in listing and name in listing and "working" in listing
    mixed = listing.splitlines()
    herdr_row = next(line.split() for line in mixed if name in line)
    tmux_row = next(line.split() for line in mixed if records[0]["name"] in line)
    assert herdr_row[-2] == "working", mixed
    assert tmux_row[-2] == "-", mixed
    run([nogg, "session", "stop", records[0]["name"]], env=env)
    run([nogg, "session", "cleanup", records[0]["name"]], env=env)

    # Read-only attach must refuse without silently granting input; regular attach reaches herdr.
    readonly = run([nogg, "session", "attach", "--read-only", name], env=env, check=False)
    assert readonly.returncode and "session log --follow" in readonly.stderr
    attach = run([nogg, "session", "attach", name], env=env, check=False)
    assert attach.returncode == 2 and "unknown command: agent attach" in attach.stderr, attach.stderr
    assert "agent attach" in calls_path.read_text()
    run([nogg, "session", "stop", name], env=env)
    stopped = json.loads((sessions / (name + ".json")).read_text())
    assert stopped["state"] == "stopped"

    # A server restart replaces pane processes. Reap records failure; cleanup closes
    # the orphaned restored pane and leaves the dedicated server running.
    again = run([nogg, "session", "launch", "--role", "lead", "--bead", "SPEC-test",
                 "--agent", "claude", "--backend", "herdr", "--ignore-usage-gate"], env=env)
    active = [json.loads(p.read_text()) for p in sessions.glob("*.json")
              if not p.name.endswith((".settings.json", ".observed.json"))
              and json.loads(p.read_text()).get("backend") == "herdr"
              and json.loads(p.read_text()).get("state") == "running"]
    assert len(active) == 1, again.stdout
    restart_name = active[0]["name"]
    run([control, "simulate-restart"], env=env)
    reaped = run([nogg, "session", "reap"], env=env)
    assert restart_name in reaped.stdout
    failed_record = json.loads((sessions / (restart_name + ".json")).read_text())
    assert failed_record["state"] == "failed"
    cleanup = run([nogg, "session", "cleanup"], env=env)
    assert "retired " + restart_name in cleanup.stdout, cleanup.stdout
    assert json.loads((sessions / (restart_name + ".json")).read_text())["state"] == "retired"
    assert not any(p.get("label") == restart_name for p in json.loads(state_file.read_text()).get("panes", {}).values())
    status = run([str(bins / "herdr"), "--session", "hdr-e2e", "status"], env=env)
    assert "status: running" in status.stdout, status.stdout

    # Packed install carries the suite and the herdr backend implementation.
    pack_dir = root / "pack"
    pack_dir.mkdir()
    npm_env = os.environ.copy()
    npm_env["npm_config_cache"] = str(root / "npm-cache")
    packed = json.loads(run(["npm", "pack", "--ignore-scripts", "--json",
                             "--pack-destination", str(pack_dir)], cwd=source, env=npm_env).stdout)[0]
    with tarfile.open(pack_dir / packed["filename"]) as archive:
        names = set(archive.getnames())
    assert "package/scripts/lib/session_backend_herdr.py" in names, sorted(names)
    assert "package/scripts/session-pty-recorder" in names, sorted(names)
    archive_dir = root / "unpacked"
    archive_dir.mkdir()
    with tarfile.open(pack_dir / packed["filename"]) as archive:
        archive.extractall(archive_dir, **({"filter": "data"} if hasattr(tarfile, "data_filter") else {}))
    consumer = root / "consumer"
    consumer.mkdir()
    subprocess.run(["git", "init", "-q", str(consumer)], check=True)
    install_env = env.copy()
    install_env["NOGGING_ROOT"] = str(consumer)
    run(["node", str(archive_dir / "package/bin/cli.js"), "init", "--no-beads",
         "--no-hooks", "--no-systemd"], cwd=consumer, env=install_env)
    assert (consumer / "scripts/lib/session_backend_herdr.py").is_file()
    assert (consumer / "scripts/session-pty-recorder").is_file()
    print("ok - herdr nogg launch, lifecycle, safety, tmux pinning and packed install")
PY
