#!/usr/bin/env bash
# `nogg dashboard` as an operator runs it: a real process in a scratch repository, with
# real signals and real exit codes. Request handling is in scripts/lib/dashboard_*_test.py.
# Offline: port 0, no `bd`, no Dolt, no sleeps. A network bind cannot be assumed here, so
# the refusals that come before a socket are what run on one.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
if [[ ! -f "$root/scripts/lib/dashboard_server_test.py" ]]; then
  echo "ok   - dashboard-server skipped (installed consumer copy)"
  exit 0
fi
PYTHONDONTWRITEBYTECODE=1 python3 - "$root" <<'PY'
from importlib.machinery import SourceFileLoader
from pathlib import Path
import json, os, select, signal, socket, stat, subprocess, sys, tempfile, urllib.request

source = Path(sys.argv[1])
nogg = source / "scripts/nogg"
failures = []


def check(name, condition, detail=""):
    print(f"{'ok  ' if condition else 'FAIL'} - {name}" + (f": {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(name)


def repository(path):
    path.mkdir(parents=True)
    subprocess.run(["bash", str(source / "scripts/lib/test-fixture-config.sh"), str(source / ".nogging/config.json"),
                    str(path / ".nogging/config.json")], check=True)
    (path / ".gitignore").write_text(".nogging/state/\n.nogging/locks/\n")
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "add", "."], check=True)
    subprocess.run(["git", "-C", str(path), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "commit", "-qm", "seed"], check=True)
    return path


def run(repo, *args, env=None):
    return subprocess.run([sys.executable, str(nogg), *args], text=True, capture_output=True, timeout=120,
                          env={**os.environ, "NOGGING_ROOT": str(repo), **(env or {})})


def start(repo, *args):
    """A foreground server, and its address once it has printed one."""
    process = subprocess.Popen([sys.executable, str(nogg), "dashboard", *args], text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               env={**os.environ, "NOGGING_ROOT": str(repo)})
    ready, _, _ = select.select([process.stdout], [], [], 30)
    line = process.stdout.readline() if ready else ""
    return process, line


def port_of(line):
    return int(line.split("http://127.0.0.1:")[1].split("/")[0])


def children(pid):
    found = []
    for task in Path(f"/proc/{pid}/task").iterdir():
        found += (task / "children").read_text().split()
    return found


def state_files(repo):
    base = repo / ".nogging/state"
    return sorted(str(p.relative_to(base)) for p in base.rglob("*") if p.is_file()) if base.exists() else []


with tempfile.TemporaryDirectory(prefix="nogg fixture ") as tmp:
    repo = repository(Path(tmp) / "main")

    # The operator starts it, and a stop leaves nothing behind.
    process, line = start(repo, "--port", "0")
    port = port_of(line) if "http://127.0.0.1:" in line else None
    check("the operator starts it and it prints its address", port is not None, line)
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=5) as reply:
        check("the shell is served from the shipped files", reply.status == 200 and b"auth.js" in reply.read())
    check("no child process runs", children(process.pid) == [])
    check("a loopback start creates no secret", not (repo / ".nogging/state/dashboard").exists())
    process.send_signal(signal.SIGTERM)
    check("SIGTERM ends it cleanly", process.wait(timeout=20) == 0)
    process.stdout.close()
    try:
        socket.create_connection(("127.0.0.1", port), timeout=5).close()
        check("the socket closes", False)
    except ConnectionRefusedError:
        check("the socket closes", True)

    process, line = start(repo, "--port", "0")
    process.send_signal(signal.SIGINT)
    check("SIGINT ends it cleanly", process.wait(timeout=20) == 0)
    process.stdout.close()

    # The default port, when this host has it free.
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind(("127.0.0.1", 8742))
            free = True
        except OSError:
            free = False
    if free:
        process, line = start(repo)
        check("the default is 127.0.0.1 on the default port", "http://127.0.0.1:8742/" in line, line)
        process.terminate()
        process.wait(timeout=20)
        process.stdout.close()

    # The port is taken.
    with socket.socket() as held:
        held.bind(("127.0.0.1", 0))
        held.listen()
        taken = held.getsockname()[1]
        result = run(repo, "dashboard", "--port", str(taken))
    check("a taken port exits non-zero", result.returncode != 0)
    check("a taken port names the port and --port", str(taken) in result.stderr and "--port" in result.stderr, result.stderr)

    # A refused address never reaches a socket, and creates no secret.
    result = run(repo, "dashboard", "--bind", "8.8.8.8")
    check("a public address is refused", result.returncode != 0 and "8.8.8.8" in result.stderr, result.stderr)
    result = run(repo, "dashboard", "--allow-host", "*.example")
    check("a wildcard --allow-host is refused", result.returncode != 0 and "--allow-host" in result.stderr, result.stderr)
    check("a refusal leaves no secret", not (repo / ".nogging/state/dashboard").exists())

    # --list-binds is a hint from `ip`, with no bind and no secret.
    stubs = Path(tmp) / "bin"
    stubs.mkdir()
    forced = Path(tmp) / "forced-env"
    (stubs / "ip").write_text(f"#!/bin/sh\nenv > '{forced}'\necho '" + json.dumps([
        {"ifname": "lo", "addr_info": [{"local": "127.0.0.1"}]},
        {"ifname": "eth0", "addr_info": [{"local": "8.8.8.8"}, {"local": "100.64.0.9"}]}]) + "'\n")
    (stubs / "ip").chmod(0o755)
    result = run(repo, "dashboard", "--list-binds", env={"PATH": f"{stubs}:{os.environ['PATH']}"})
    check("--list-binds prints eligible addresses only",
          result.returncode == 0 and "127.0.0.1" in result.stdout and "8.8.8.8" not in result.stdout, result.stdout)
    check("--list-binds warns about carrier NAT", "carrier NAT" in result.stdout, result.stdout)
    seen = forced.read_text().splitlines()
    check("the read-only environment is forced for every child",
          all(line in seen for line in ("BEADS_DOLT_AUTO_START=0", "GIT_OPTIONAL_LOCKS=0", "DOLT_DISABLE_EVENT_FLUSH=1")), seen)

    # Rotation.
    secret = repo / ".nogging/state/dashboard/secret"
    result = run(repo, "dashboard", "--rotate-token")
    first = secret.read_text().strip()
    check("--rotate-token creates the secret 0600 in 0700",
          result.returncode == 0 and stat.S_IMODE(secret.stat().st_mode) == 0o600
          and stat.S_IMODE(secret.parent.stat().st_mode) == 0o700, result.stderr)
    check("--rotate-token never prints the secret", first not in result.stdout + result.stderr)
    run(repo, "dashboard", "--rotate-token")
    check("--rotate-token replaces it", secret.read_text().strip() != first)
    linked = Path(tmp) / "linked"
    subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", "-b", "linked", str(linked)], check=True)
    before = secret.read_text()
    run(linked, "dashboard", "--rotate-token")
    check("a linked worktree rotates the canonical secret",
          secret.read_text() != before and not (linked / ".nogging/state/dashboard").exists())

    # The secret is too open: refused before any socket, on an address nobody owns.
    secret.chmod(0o644)
    result = run(repo, "dashboard", "--bind", "10.255.255.1", "--port", "0")
    check("an open secret refuses a network start",
          result.returncode != 0 and str(secret) in result.stderr and "0600" in result.stderr, result.stderr)
    secret.chmod(0o600)

    # A supervised session asks for a network bind.
    loader = SourceFileLoader("dashboard_fixture", str(nogg))
    os.environ["NOGGING_ROOT"] = str(repo)
    module = loader.load_module()
    del os.environ["NOGGING_ROOT"]
    sessions = repo / ".nogging/state/sessions"
    sessions.mkdir(parents=True, exist_ok=True)
    (sessions / "lead.json").write_text(json.dumps(
        {"name": "lead", "bead_id": "SPEC-x", "role": "lead", "state": "running", "session_pid": os.getpid(),
         "session_pid_start": module.process_start(os.getpid())}))
    result = run(repo, "dashboard", "--bind", "10.255.255.1", "--port", "0")
    check("a supervised session cannot bind a network address",
          result.returncode != 0 and "supervised session" in result.stderr, result.stderr)
    process, line = start(repo, "--port", "0")
    check("a supervised session can still use loopback", "http://127.0.0.1:" in line, line)
    process.terminate()
    process.wait(timeout=20)
    process.stdout.close()
    (sessions / "lead.json").unlink()
    result = run(repo, "dashboard", "--bind", "10.255.255.1", "--port", "0", env={"NOGG_SESSION_NAME": "made-up"})
    check("an unproven session environment fails closed",
          result.returncode != 0 and "made-up" in result.stderr, result.stderr)

    # Doctor is silent when unused and warns on an open secret.
    fresh = repository(Path(tmp) / "unused")
    result = run(fresh, "doctor")
    check("doctor on an unused install says nothing about the dashboard",
          "dashboard" not in (result.stdout + result.stderr).lower(), result.stdout)
    check("doctor creates no dashboard state", not (fresh / ".nogging/state/dashboard").exists())
    run(fresh, "dashboard", "--rotate-token")
    result = run(fresh, "doctor")
    check("doctor is silent on a safe secret", "dashboard secret" not in result.stdout + result.stderr, result.stdout)
    target = fresh / ".nogging/state/dashboard/secret"
    target.chmod(0o644)
    result = run(fresh, "doctor")
    output = result.stdout + result.stderr
    check("doctor warns on an open secret", "dashboard secret" in output and str(target) in output and "0644" in output, output)
    check("doctor never prints the secret", target.read_text().strip() not in output)

sys.exit(1 if failures else 0)
PY
