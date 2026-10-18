#!/usr/bin/env bash
# Planner shutdown waits for its owner before releasing the canonical lock.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
python3 - "$root" <<'PY'
import datetime, importlib.machinery, importlib.util, json, os, pathlib, subprocess, sys, tempfile, threading, time

source = pathlib.Path(sys.argv[1]) / "scripts/nogg"
os.environ.pop("NOGG_OPENSPEC_FENCED", None)
loader = importlib.machinery.SourceFileLoader("nogg_close_order", str(source))
spec = importlib.util.spec_from_loader(loader.name, loader)
nogg = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = nogg
spec.loader.exec_module(nogg)

def fixture(grace):
    tmp = tempfile.TemporaryDirectory()
    repo = pathlib.Path(tmp.name)
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    state = repo / ".nogging"
    (state / "locks").mkdir(parents=True)
    sessions = state / "state/sessions"
    sessions.mkdir(parents=True)
    (state / "config.json").write_text(json.dumps({"session_stop_grace_seconds": grace}))
    nogg.ROOT = repo
    nogg.CFG = {"session_stop_grace_seconds": grace}
    return tmp, repo, sessions, state / "locks/planning.lock"

def process_start(pid):
    return pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]

def owner_lock(repo, name, proc):
    return {"session_name": name, "session_root": str(repo), "host": nogg.socket.gethostname(),
            "pid": proc.pid, "pid_start": process_start(proc.pid), "pid_ns": nogg.pid_namespace(proc.pid),
            "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}

def setup(grace):
    tmp, repo, sessions, lock_path = fixture(grace)
    owner = subprocess.Popen(["sleep", "30"])
    name = "planner-fixture"
    record = {"name": name, "bead_id": None, "role": "planning", "host": nogg.socket.gethostname(),
              "state": "running", "session_pid": owner.pid, "session_pid_start": process_start(owner.pid),
              "session_pid_ns": nogg.pid_namespace(owner.pid), "backend": "tmux", "backend_ref": {"name": name},
              "usage_gate": {}, "usage_started_at": None}
    path = sessions / f"{name}.json"
    path.write_text(json.dumps(record))
    lock_path.write_text(json.dumps(owner_lock(repo, name, owner)))
    nogg.load_session = lambda requested: (path, json.loads(path.read_text()))
    nogg.tmux_has_session = lambda _: False
    nogg.collect_session_usage = lambda *a, **k: None
    nogg.record_session_usage = lambda *a, **k: None
    return tmp, repo, sessions, lock_path, owner, path, name

# Owner exits within grace: lock release follows the process exit, without force.
tmp, repo, sessions, lock, owner, path, name = setup(5)
threading.Thread(target=lambda: (time.sleep(.25), owner.terminate(), owner.wait()), daemon=True).start()
nogg.session_stop(name, "test")
assert not lock.exists(), "planner lock should release after owner exits"
assert json.loads(path.read_text())["state"] == "stopped"
tmp.cleanup()

# Owner exceeds grace: keep lock and give the exact safe retry instruction.
tmp, repo, sessions, lock, owner, path, name = setup(.1)
from contextlib import redirect_stdout
from io import StringIO
output = StringIO()
with redirect_stdout(output):
    nogg.session_stop(name, "test")
assert lock.exists(), "live planner lock must remain"
assert f"rerun 'nogg session stop {name}'" in output.getvalue()
owner.terminate(); owner.wait()
with redirect_stdout(output):
    nogg.session_stop(name, "test")
assert not lock.exists(), "a second stop should release the exited owner's lock"
tmp.cleanup()

# A different role must not inspect or release the planning owner's lock.
tmp, repo, sessions, lock, owner, path, name = setup(.1)
owner.terminate(); owner.wait()
record = json.loads(path.read_text())
record["role"] = "lead"
record["state"] = "running"
path.write_text(json.dumps(record))
with redirect_stdout(output):
    nogg.session_stop(name, "test")
assert lock.exists(), "execution-role stop must preserve the planner's lock"
tmp.cleanup()

# plan-end from a linked planning worktree releases the main checkout's lock.
tmp = tempfile.TemporaryDirectory()
main = pathlib.Path(tmp.name) / "main"
linked = pathlib.Path(tmp.name) / "planning"
main.mkdir()
subprocess.run(["git", "init", "-q", str(main)], check=True)
subprocess.run(["git", "-C", str(main), "-c", "user.name=Test", "-c", "user.email=test@example.com",
                "commit", "--allow-empty", "-qm", "fixture"], check=True)
subprocess.run(["git", "-C", str(main), "worktree", "add", "-qb", "planning", str(linked)], check=True)
state = main / ".nogging"
locks = state / "locks"
sessions = state / "state/sessions"
locks.mkdir(parents=True)
sessions.mkdir(parents=True)
(state / "config.json").write_text(json.dumps({"session_state_dir": ".nogging/state/sessions"}))
name = "plan-end-fixture"
owner = {"session_name": name, "session_root": str(main), "host": nogg.socket.gethostname(),
         "pid": os.getpid(), "pid_start": process_start(os.getpid()), "pid_ns": nogg.pid_namespace(),
         "working_dir": str(linked), "planning_id": "fixture",
         "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
(locks / "planning.lock").write_text(json.dumps(owner))
(sessions / f"{name}.json").write_text(json.dumps({
    "name": name, "bead_id": None, "role": "planning", "state": "running",
    "session_pid": os.getpid(), "session_pid_start": owner["pid_start"],
    "session_pid_ns": owner["pid_ns"], "working_dir": str(linked), "planning_id": "fixture"}))
nogg.ROOT = linked
nogg.CFG = {"session_state_dir": ".nogging/state/sessions"}
nogg.STATE = main / ".nogging/state"
nogg.ORCHESTRATOR_HOME = main
nogg.PLANNING_LOCKS = locks
nogg.SENTINEL = locks / "openspec.readonly"
saved_env = {key: os.environ.get(key) for key in
             ("NOGG_SESSION_NAME", "NOGG_SESSION_ROLE", "NOGG_SESSION_ROOT")}
os.environ.update(NOGG_SESSION_NAME=name, NOGG_SESSION_ROLE="planning", NOGG_SESSION_ROOT=str(main))
saved_argv = sys.argv[:]
sys.argv = [str(source), "plan-end"]
nogg.main()
sys.argv = saved_argv
assert not (locks / "planning.lock").exists(), "canonical planning lock should be removed"
assert (locks / "openspec.readonly").exists(), "canonical sentinel should be written"
for key in ("NOGG_SESSION_NAME", "NOGG_SESSION_ROLE", "NOGG_SESSION_ROOT"):
    if saved_env[key] is None:
        os.environ.pop(key, None)
    else:
        os.environ[key] = saved_env[key]
tmp.cleanup()

# Recovery points at session stop when its interrupted owner's record remains.
tmp, repo, sessions, lock, owner, path, name = setup(0)
owner.terminate(); owner.wait()
lock.write_text(json.dumps({"session_name": name, "session_root": str(repo),
    "host": nogg.socket.gethostname(), "pid": 99999999, "pid_start": "missing",
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}))
nogg.CFG = {"planning_lock_ttl_seconds": 7200, "session_state_dir": ".nogging/state/sessions"}
nogg.STATE = repo / ".nogging/state"
nogg.PLANNING_LOCKS = repo / ".nogging/locks"
nogg.ORCHESTRATOR_LOCKS = nogg.PLANNING_LOCKS
nogg.LOCKS = nogg.PLANNING_LOCKS
nogg.orchestrator_local_lock_note = lambda: None
nogg.beads = lambda: []
nogg.recover_base_branch = lambda: None
nogg.resolve_ref = lambda *_: None
nogg.commit_tokens_with_subject = lambda *_: {}
nogg.validate = lambda **_: ([], [], [], [])
nogg.recorded_worktree_lines = lambda: ([], [])
_, attention = nogg.recover_scan()
assert any(f"interrupted planning owner {name}" in line
           and f"nogg session stop {name}" in line for line in attention), attention
tmp.cleanup()
print("ok - planning close order")
PY
