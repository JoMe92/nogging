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
import json, os, pty, select, signal, socket, stat, subprocess, sys, tempfile, threading, time, urllib.request

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
    """No terminal: stdin is /dev/null, as for an agent's tool call or `ssh host cmd`."""
    return subprocess.run([sys.executable, str(nogg), *args], text=True, capture_output=True, timeout=120,
                          stdin=subprocess.DEVNULL, env={**os.environ, "NOGGING_ROOT": str(repo), **(env or {})})


LOGIN = "0::/user.slice/user-1000.slice/session-3.scope\n"
APP_SLICE = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-u7.scope\n"
# `nogg` in its own process, with the host facts of the operator-terminal test injected
# there: no environment variable can stand in for them, so no test hook can lift the rule.
DRIVER = """
import fcntl, json, os, sys, termios
from importlib.machinery import SourceFileLoader
facts = json.loads(sys.argv[2])
if os.isatty(0):
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)       # /dev/tty is this pseudo-terminal, never the runner's
module = SourceFileLoader("nogg_on_terminal", sys.argv[1]).load_module()
module.read_login_cgroup = lambda: facts["cgroup"]
module.session_server_processes = lambda: [tuple(server) for server in facts["servers"]]
if facts.get("network_loopback"):
    # A loopback socket under the network rules: the token, the terminal test and the
    # audit trail all run, and nothing listens beyond this host.
    security = module.dashboard_modules()[0]
    real = security.check_bind
    security.check_bind = lambda value: (security.Bind("127.0.0.1", None, False)
                                         if value == facts["network_loopback"] else real(value))
sys.argv = ["nogg", *facts["args"]]
try:
    module.main()
except Exception as exc:
    print(f"nogg: {exc}", file=sys.stderr)
    sys.exit(1)
"""


def on_terminal(repo, *args, cgroup=LOGIN, servers=(), piped=False, env=None, typed=None):
    """(exit code, terminal output, piped stdout) of `nogg` with a pseudo-terminal on stdin
    and stderr, and on stdout unless `piped`; the terminal is the child's controlling one,
    and `typed` is a line typed into it. Only refusals and one-shot steps run here."""
    master, slave = pty.openpty()
    facts = json.dumps({"args": list(args), "cgroup": cgroup, "servers": [list(s) for s in servers]})
    environment = {key: value for key, value in os.environ.items() if key != "NOGG_SESSION_NAME"}
    environment.update(NOGGING_ROOT=str(repo), **(env or {}))
    process = subprocess.Popen([sys.executable, "-c", DRIVER, str(nogg), facts], stdin=slave, stderr=slave,
                               stdout=subprocess.PIPE if piped else slave, env=environment,
                               start_new_session=True)
    os.close(slave)
    if typed is not None:
        os.write(master, typed.encode() + b"\n")
    output = b""
    while True:
        ready, _, _ = select.select([master], [], [], 60)
        if not ready:
            process.kill()
            break
        try:
            chunk = os.read(master, 4096)
        except OSError:            # EIO: the child has closed the terminal
            break
        if not chunk:
            break
        output += chunk
    os.close(master)
    piped_output = process.stdout.read().decode(errors="replace") if piped else ""
    if piped:
        process.stdout.close()
    return process.wait(timeout=60), output.decode(errors="replace"), piped_output


def driven(repo, *args, cgroup=LOGIN, env=None):
    """`nogg` with injected host facts and no terminal: stdin /dev/null, output captured."""
    facts = json.dumps({"args": list(args), "cgroup": cgroup, "servers": []})
    environment = {key: value for key, value in os.environ.items() if key != "NOGG_SESSION_NAME"}
    environment.update(NOGGING_ROOT=str(repo), **(env or {}))
    return subprocess.run([sys.executable, "-c", DRIVER, str(nogg), facts], text=True, capture_output=True,
                          timeout=120, stdin=subprocess.DEVNULL, env=environment)


def terminal_run(repo, address, env):
    """A foreground network run on an operator terminal, bound to loopback under the
    network rules, stopped with SIGTERM once it has printed its address. Its output holds
    the token link, so a check never prints it."""
    master, slave = pty.openpty()
    facts = json.dumps({"args": ["dashboard", "--bind", address, "--port", "0"], "cgroup": LOGIN, "servers": [],
                        "network_loopback": address})
    environment = {key: value for key, value in os.environ.items() if key != "NOGG_SESSION_NAME"}
    environment.update(NOGGING_ROOT=str(repo), **env)
    process = subprocess.Popen([sys.executable, "-c", DRIVER, str(nogg), facts], stdin=slave, stdout=slave,
                               stderr=slave, env=environment, start_new_session=True)
    os.close(slave)
    output, stopped = b"", False
    while True:
        ready, _, _ = select.select([master], [], [], 60)
        if not ready:
            break
        try:
            chunk = os.read(master, 4096)
        except OSError:
            break
        if not chunk:
            break
        output += chunk
        if not stopped and b"Nogging dashboard on" in output:
            process.send_signal(signal.SIGTERM)
            stopped = True
    os.close(master)
    if process.poll() is None:
        process.kill()
    return process.wait(timeout=60), output.decode(errors="replace")


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
    """The children of every thread of `pid`. A thread may end while this walks them."""
    found = []
    for task in Path(f"/proc/{pid}/task").iterdir():
        try:
            found += (task / "children").read_text().split()
        except OSError:
            pass
    return found


def settled(port, seconds=30):
    """Whether every source has finished its first turn: the refresher runs Git and Dolt
    in the background, so only then does a child process mean that a request left one."""
    deadline, tick = time.monotonic() + seconds, threading.Event()
    while time.monotonic() < deadline:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v1/freshness", timeout=5) as reply:
            states = [item["state"] for item in json.loads(reply.read())["data"].values()]
        if states and not {"loading", "refreshing"} & set(states):
            return True
        tick.wait(0.05)
    return False


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
    check("every source settles", settled(port))
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
          all(line in seen for line in ("BEADS_DOLT_AUTO_START=0", "GIT_OPTIONAL_LOCKS=0", "DOLT_DISABLE_EVENT_FLUSH=1")))

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
    # It runs on an operator terminal, so that the terminal rule is not what refuses it.
    secret.chmod(0o644)
    code, output, _ = on_terminal(repo, "dashboard", "--bind", "10.255.255.1", "--port", "0")
    check("an open secret refuses a network start",
          code != 0 and str(secret) in output and "0600" in output and "operator terminal" not in output, output)
    check("the refused start prints no token", secret.read_text().strip() not in output)
    # A terminal with piped output passes the terminal rule: only stdin is tested.
    code, output, piped = on_terminal(repo, "dashboard", "--bind", "10.255.255.1", "--port", "0", piped=True)
    check("a terminal with piped output passes the terminal rule",
          code != 0 and "0600" in output and "operator terminal" not in output and "http" not in piped, output)
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
    unchanged = ("refusing --bind 10.255.255.1 inside a supervised session: the token would reach the "
                 "session log, and network exposure stays an operator act")
    result = run(repo, "dashboard", "--bind", "10.255.255.1", "--port", "0")
    check("a supervised session cannot bind a network address",
          result.returncode != 0 and unchanged in result.stderr, result.stderr)
    code, output, _ = on_terminal(repo, "dashboard", "--bind", "10.255.255.1", "--port", "0")
    check("a supervised session on a login terminal keeps the unchanged refusal",
          code != 0 and unchanged in output.replace("\r\n", " ") and "operator terminal" not in output, output)
    process, line = start(repo, "--port", "0")
    check("a supervised session can still use loopback", "http://127.0.0.1:" in line, line)
    process.terminate()
    process.wait(timeout=20)
    process.stdout.close()
    (sessions / "lead.json").unlink()
    result = run(repo, "dashboard", "--bind", "10.255.255.1", "--port", "0", env={"NOGG_SESSION_NAME": "made-up"})
    check("an unproven session environment fails closed",
          result.returncode != 0 and "made-up" in result.stderr, result.stderr)
    code, output, _ = on_terminal(repo, "dashboard", "--bind", "10.255.255.1", "--port", "0",
                                  env={"NOGG_SESSION_NAME": "made-up"})
    check("an unproven session name fails closed on a login terminal too", code != 0 and "made-up" in output, output)

    # Outside a session, a network bind needs an operator terminal; each refusal comes
    # before a socket and before a secret, so no token exists to be printed.
    bare = repository(Path(tmp) / "bare")
    bare_secret = bare / ".nogging/state/dashboard/secret"
    result = run(bare, "dashboard", "--bind", "10.255.255.1", "--port", "0")
    check("a network bind without a terminal is refused",
          result.returncode != 0 and "outside an operator terminal" in result.stderr
          and "stdin is not a terminal" in result.stderr and "nogg dashboard service enable" in result.stderr,
          result.stderr)
    check("a remote command without a terminal is told to use ssh -t", "ssh -t" in result.stderr, result.stderr)
    code, output, _ = on_terminal(bare, "dashboard", "--bind", "10.255.255.1", "--port", "0", cgroup=APP_SLICE)
    check("a pseudo-terminal outside a login session is refused",
          code != 0 and "logind session scope" in output and "app.slice" in output, output)
    check("a pseudo-terminal outside a login session prints no link", "http" not in output, output)
    code, output, _ = on_terminal(bare, "dashboard", "--bind", "10.255.255.1", "--port", "0",
                                  servers=[("tmux server -L nogging", os.getpid(), module.process_start(os.getpid()))])
    check("a pane on the shared session server is refused",
          code != 0 and "shared Nogging session server" in output and "http" not in output, output)
    check("no refusal of the terminal rule creates a secret", not os.path.lexists(bare_secret))
    code, output, _ = on_terminal(bare, "dashboard", "--bind", "8.8.8.8", "--port", "0")
    check("the bind policy still comes first", code != 0 and "8.8.8.8" in output and "operator terminal" not in output,
          output)

    # Doctor is silent when unused and warns on an open secret.
    fresh = repository(Path(tmp) / "unused")
    result = run(fresh, "doctor", env={"XDG_CONFIG_HOME": str(Path(tmp) / "xdg")})
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

    # The consented service. Stubs stand in for systemctl, loginctl and systemd-cat; the
    # user unit directory is a temporary XDG_CONFIG_HOME, so no real unit is written.
    stubs = Path(tmp) / "service-bin"
    stubs.mkdir()
    calls, unit_state = Path(tmp) / "systemctl.log", Path(tmp) / "unit-state"
    unit_state.mkdir()
    (stubs / "systemctl").write_text(
        f"#!/bin/sh\necho \"$*\" >> '{calls}'\n"
        f"case \"$2\" in is-enabled) cat '{unit_state}/enabled' 2>/dev/null || echo disabled ;;\n"
        f"  is-active) cat '{unit_state}/active' 2>/dev/null || echo inactive ;; esac\nexit 0\n")
    (stubs / "loginctl").write_text("#!/bin/sh\necho Linger=no\n")
    journal = Path(tmp) / "journal.log"
    (stubs / "systemd-cat").write_text(f"#!/bin/sh\necho \"$*\" >> '{journal}'\ncat >> '{journal}'\n")
    for name in ("systemctl", "loginctl", "systemd-cat"):
        (stubs / name).chmod(0o755)
    units = Path(tmp) / "xdg/systemd/user"
    service_env = {"PATH": f"{stubs}:{os.environ['PATH']}", "XDG_CONFIG_HOME": str(Path(tmp) / "xdg")}

    def systemctl_calls():
        return calls.read_text().splitlines() if calls.exists() else []

    def reset_calls():
        if calls.exists():
            calls.unlink()

    def events(target):
        path = target / ".nogging/state/dashboard/audit.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def mode(path):
        return stat.S_IMODE(path.stat().st_mode)

    UNIT_OF = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/nogg-dashboard-{}.service\n"

    def session_record(target, name, role):
        directory = target / ".nogging/state/sessions"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / f"{name}.json").write_text(json.dumps(
            {"name": name, "bead_id": None if role == "orchestrator" else "SPEC-x", "role": role,
             "state": "running", "session_pid": os.getpid(), "session_pid_start": module.process_start(os.getpid())}))
        return directory / f"{name}.json"

    # The operator enables the service, and the secret stays out of everything it writes.
    served = repository(Path(tmp) / "served")
    code, output, _ = on_terminal(served, "dashboard", "service", "enable", "--bind", "100.86.79.27",
                                  env=service_env, typed="100.86.79.27")
    consent = served / ".nogging/state/dashboard/consent.json"
    unit = units / "nogg-dashboard-served.service"
    check("the operator enables the service", code == 0 and consent.exists() and mode(consent) == 0o600, output)
    check("the unit is written for the canonical checkout",
          unit.exists() and f'ExecStart="{served}/scripts/nogg" dashboard service run' in unit.read_text())
    check("the unit is reloaded, enabled and started",
          "--user daemon-reload" in systemctl_calls()
          and "--user enable --now nogg-dashboard-served.service" in systemctl_calls(), systemctl_calls())
    check("the consent is recorded", [e["event"] for e in events(served)] == ["consent"]
          and events(served)[0]["bind"] == "100.86.79.27" and events(served)[0]["tty"].startswith("/dev/"))
    check("the consent reaches the journal", "-t nogg-dashboard" in journal.read_text()
          and '"event":"consent"' in journal.read_text())
    check("a lingering-off note is printed", "lingering is off" in output, output)
    served_secret = (served / ".nogging/state/dashboard/secret").read_text().strip()
    check("the secret stays out of the unit", served_secret not in unit.read_text()
          and served_secret not in consent.read_text() and served_secret not in "".join(systemctl_calls()))
    check("enable prints no token", served_secret not in output and "#token=" not in output)
    result = driven(served, "doctor", env=service_env)
    check("doctor with a consented service notes it",
          "100.86.79.27 port 8742" in result.stdout and "dashboard: nogg-dashboard-served.service exists or runs"
          not in result.stdout, result.stdout[-2000:])

    # A consent does not lift the session refusal; status reads from anywhere.
    session_record(served, "lead-x", "lead")
    before = state_files(served)
    result = driven(served, "dashboard", "status", env=service_env)
    check("status from anywhere", result.returncode == 0 and "100.86.79.27 port 8742" in result.stdout
          and '"event":"consent"' in result.stdout and state_files(served) == before, result.stdout + result.stderr)
    result = run(served, "dashboard", "--bind", "100.86.79.27", "--port", "0")
    check("a consent does not lift the session refusal",
          result.returncode != 0 and unchanged.replace("10.255.255.1", "100.86.79.27") in result.stderr, result.stderr)
    (served / ".nogging/state/dashboard/secret").unlink()
    result = run(served, "dashboard", "--bind", "100.86.79.27", "--port", "0")
    check("the refused session creates no secret", not (served / ".nogging/state/dashboard/secret").exists())
    result = driven(served, "dashboard", "service", "run", cgroup=UNIT_OF.format("served"), env=service_env)
    check("the service inside a session is refused",
          result.returncode == 78 and "inside a supervised session" in result.stderr, result.stderr)

    # A Lead cannot switch it off; the Orchestration Agent can.
    reset_calls()
    before = state_files(served)
    result = driven(served, "dashboard", "service", "disable", env=service_env)
    check("a Lead tries to switch it off", result.returncode != 0 and unit.exists()
          and state_files(served) == before and systemctl_calls() == [], result.stderr)
    (served / ".nogging/state/sessions/lead-x.json").unlink()
    orchestrator = session_record(served, "nogg-orchestrator-served", "orchestrator")
    (unit_state / "active").write_text("active\n")
    result = driven(served, "dashboard", "--rotate-token", env=service_env)
    check("the token is rotated from the chat", result.returncode == 0 and events(served)[-1]["event"] == "rotated"
          and "consented service" in result.stdout and "nogg dashboard pair" not in result.stdout, result.stdout)
    check("the rotation prints no secret",
          (served / ".nogging/state/dashboard/secret").read_text().strip() not in result.stdout + result.stderr)
    result = driven(served, "dashboard", "service", "disable", env=service_env)
    check("the orchestrator switches it off", result.returncode == 0 and not unit.exists() and not consent.exists()
          and "--user disable --now nogg-dashboard-served.service" in systemctl_calls(), result.stderr)
    check("the revocation names the orchestrator", events(served)[-1] == {
        **events(served)[-1], "event": "revoked", "caller": "orchestrator:nogg-orchestrator-served"})
    orchestrator.unlink()
    (unit_state / "active").unlink()
    count = len(events(served))
    code, output, _ = on_terminal(served, "dashboard", "service", "disable", env=service_env)
    check("disabled twice", code == 0 and "nothing to disable" in output and len(events(served)) == count, output)

    # Refusals of enable write nothing and call no systemctl.
    refused = repository(Path(tmp) / "refused")
    def untouched(name):
        check(name + ": nothing written", not (refused / ".nogging/state/dashboard").exists()
              and not (units / "nogg-dashboard-refused.service").exists())
        check(name + ": no systemctl call", systemctl_calls() == [], systemctl_calls())
    reset_calls()
    code, output, _ = on_terminal(refused, "dashboard", "service", "enable", "--bind", "100.86.79.27",
                                  env=service_env, typed="100.86.79.28")
    check("a mistyped confirmation is refused", code != 0 and "does not match" in output, output)
    untouched("a mistyped confirmation")
    for role, name in (("lead", "lead-y"), ("orchestrator", "nogg-orchestrator-refused")):
        record = session_record(refused, name, role)
        code, output, _ = on_terminal(refused, "dashboard", "service", "enable", "--bind", "100.86.79.27",
                                      env=service_env, typed="100.86.79.27")
        check(f"a session asks to enable ({role})", code != 0 and name in output, output)
        record.unlink()
    untouched("a session asks to enable")
    result = driven(refused, "dashboard", "service", "enable", "--bind", "100.86.79.27", env=service_env)
    check("no terminal: enable is refused", result.returncode != 0 and "stdin is not a terminal" in result.stderr,
          result.stderr)
    code, output, _ = on_terminal(refused, "dashboard", "service", "enable", "--bind", "100.86.79.27",
                                  cgroup=APP_SLICE, env=service_env, typed="100.86.79.27")
    check("outside a login session scope: enable is refused", code != 0 and "logind session scope" in output, output)
    code, output, _ = on_terminal(refused, "dashboard", "service", "enable", "--bind", "100.86.79.27",
                                  piped=True, env=service_env, typed="100.86.79.27")
    check("piped stdout: enable is refused", code != 0 and "stdout is not a terminal" in output, output)
    bare_bin = Path(tmp) / "no-systemctl"
    bare_bin.mkdir()
    for tool in ("git", "sh", "bash", "env"):
        found = subprocess.run(["sh", "-c", f"command -v {tool}"], text=True, capture_output=True).stdout.strip()
        if found:
            (bare_bin / tool).symlink_to(found)
    code, output, _ = on_terminal(refused, "dashboard", "service", "enable", "--bind", "100.86.79.27",
                                  env={**service_env, "PATH": str(bare_bin)}, typed="100.86.79.27")
    check("a host without systemctl", code != 0 and "no `systemctl`" in output
          and "nogg dashboard --bind 100.86.79.27" in output, output)
    untouched("a host without systemctl")

    # `service run`: only the unit runs it, and only with a valid consent.
    lone = repository(Path(tmp) / "lone")
    lone_unit = UNIT_OF.format("lone")
    result = driven(lone, "dashboard", "service", "run", cgroup=lone_unit, env=service_env)
    check("no consent", result.returncode == 78 and "nogg dashboard service enable" in result.stderr, result.stderr)
    check("no consent opens no socket", not (lone / ".nogging/state/dashboard/control.sock").exists())
    writer = module.dashboard_service_module()
    lone_consent = lone / ".nogging/state/dashboard/consent.json"
    for address in ("8.8.8.8", "0.0.0.0"):
        writer.write_consent(lone_consent, writer.consent_record(address, 8742, [], "2026-11-02T10:00:00Z", "/dev/pts/1"))
        result = driven(lone, "dashboard", "service", "run", cgroup=lone_unit, env=service_env)
        check(f"a tampered consent naming {address}", result.returncode == 78, result.stderr)
    writer.write_consent(lone_consent, writer.consent_record("10.255.255.1", 8742, [], "2026-11-02T10:00:00Z",
                                                             "/dev/pts/1"))
    lone_consent.chmod(0o644)
    result = driven(lone, "dashboard", "service", "run", cgroup=lone_unit, env=service_env)
    check("a tampered consent with mode 0644", result.returncode == 78 and "0644" in result.stderr, result.stderr)
    lone_consent.chmod(0o600)
    control = lone / ".nogging/state/dashboard/control.sock"
    live = None
    if len(os.fsencode(str(control))) <= 107:
        live = socket.socket(socket.AF_UNIX)
        live.bind(str(control))
    else:
        control.write_text("")
    identity = control.lstat().st_ino
    result = driven(lone, "dashboard", "service", "run", cgroup=APP_SLICE, env=service_env)
    check("a start beside the unit", result.returncode == 78 and "app.slice" in result.stderr, result.stderr)
    check("a start beside the unit leaves the control socket", control.exists() and control.lstat().st_ino == identity)
    if live is not None:
        live.close()
    control.unlink()
    result = driven(lone, "dashboard", "service", "run", cgroup=lone_unit, env=service_env)
    lone_secret = (lone / ".nogging/state/dashboard/secret").read_text().strip()
    check("an address that is not up exits for a retry", result.returncode == 1
          and "not assigned to this host" in result.stderr, result.stderr)
    check("the service prints no token", lone_secret not in result.stdout + result.stderr
          and "#token=" not in result.stdout + result.stderr)
    check("a failed start records no exposure", [e["event"] for e in events(lone)] == [])

    # A terminal run is recorded: `started` with mode `terminal`, then `stopped`.
    code, output = terminal_run(lone, "10.255.255.1", service_env)
    rows = events(lone)
    check("a terminal run is recorded", code == 0 and [e["event"] for e in rows] == ["started", "stopped"]
          and rows[0]["mode"] == "terminal" and rows[0]["pid"] > 0 and rows[0]["port"] > 0,
          "exit %s, events %s" % (code, [e.get("event") for e in rows]))
    secret_now = (lone / ".nogging/state/dashboard/secret").read_text().strip()
    audit_text = (lone / ".nogging/state/dashboard/audit.jsonl").read_text()
    check("the terminal run's events hold no token", secret_now not in audit_text and "token" not in audit_text)
    check("the terminal run reaches the journal", '"mode":"terminal"' in journal.read_text())

    # Doctor with a unit and no consent.
    orphan = repository(Path(tmp) / "orphan")
    (units / "nogg-dashboard-orphan.service").write_text("[Service]\n")
    result = driven(orphan, "doctor", env=service_env)
    check("doctor with a unit and no consent warns",
          "nogg-dashboard-orphan.service exists or runs without a valid consent" in result.stdout
          and "nogg dashboard service disable" in result.stdout, result.stdout[-2000:])

sys.exit(1 if failures else 0)
PY
