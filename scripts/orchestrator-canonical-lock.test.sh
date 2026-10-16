#!/usr/bin/env bash
# TASK-HSS-003: canonical singleton state across linked worktrees.
# All services and bd are stubbed; only our own child is used for PID liveness.
set -euo pipefail
for var in $(compgen -v | grep -E '^(NOGG_|HERDR_|TMUX)' || true); do
  unset "$var"
done
unset NOGGING_ROOT
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d /tmp/nogg.XXXXXX)
trap 'rm -rf "$work"' EXIT
python3 - "$repo_root" "$work" <<'PY'
import importlib.machinery
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys

source, work = map(Path, sys.argv[1:])
main, linked = work / "main-repo", work / "different-worktree"
main.mkdir()
bin_dir = work / "bin"
bin_dir.mkdir()
calls = work / "service-calls"
tmux_live = work / "tmux-live"
env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
           STUB_CALLS=str(calls), STUB_LIVE=str(tmux_live), AGY_NOGG_USAGE_PROBE="0",
           CODEX_HOME=str(work / "codex"), XDG_CACHE_HOME=str(work / "cache"))

def stub(name, body):
    path = bin_dir / name
    path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body + "\n")
    path.chmod(0o755)

stub("bd", "printf '[]\\n'")
stub("dolt", ":")
stub("claude", ":")
for agent in ("codex", "pi", "agy", "herdr"):
    stub(agent, "exit 1")
stub("systemctl", '''
printf 'systemctl %s\\n' "$*" >>"$STUB_CALLS"
case "${2:-}" in
  is-enabled) echo enabled ;;
  is-active) echo active ;;
esac''')
stub("loginctl", "echo Linger=yes")
stub("tmux", '''
printf 'tmux %s\\n' "$*" >>"$STUB_CALLS"
[[ "${1:-}" == -L ]] && shift 2
cmd="${1:-}"; shift || true
case "$cmd" in
  list-sessions) cat "$STUB_LIVE" 2>/dev/null || true ;;
  has-session) [[ -s "$STUB_LIVE" ]] ;;
  new-session)
    while [[ $# -gt 0 ]]; do
      [[ "$1" == -s ]] && { echo "$2" >"$STUB_LIVE"; break; }
      shift
    done ;;
  send-keys|kill-session) : >"$STUB_LIVE" ;;
esac''')

def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], env=env,
                          check=True, capture_output=True, text=True).stdout

shutil.copytree(source / ".nogging/launch-profiles", main / ".nogging/launch-profiles")
shutil.copytree(source / ".nogging/launch-prompts", main / ".nogging/launch-prompts")
(main / "scripts").symlink_to(source / "scripts", target_is_directory=True)
config = json.loads((source / ".nogging/config.json").read_text())
config.update(beads_command="bd", session_backend="tmux", agent_state_roots={},
              session_stop_grace_seconds=0, usage_gate={"enabled": False})
(main / ".nogging/config.json").write_text(json.dumps(config))
git(main, "init", "-q", "-b", "develop")
git(main, "config", "user.name", "Test Runner")
git(main, "config", "user.email", "tests@example.invalid")
git(main, "add", ".")
git(main, "commit", "-qm", "chore: seed fixture [SPEC-000]")
git(main, "worktree", "add", "-qb", "chore/fixture", str(linked))

def cli(root, *args, ok=True):
    result = subprocess.run([str(source / "scripts/nogg"), *args], cwd=root,
                            env=dict(env, NOGGING_ROOT=str(root)),
                            capture_output=True, text=True, timeout=30)
    if ok:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result

def load(root, name):
    os.environ.update(env, NOGGING_ROOT=str(root))
    return importlib.machinery.SourceFileLoader(name, str(source / "scripts/nogg")).load_module()

mod = load(linked, "nogg_linked")
main_mod = load(main, "nogg_main")
lock = main / ".nogging/locks/orchestrator.lock"
local_lock = linked / ".nogging/locks/orchestrator.lock"
name = "nogg-orchestrator-main-repo"
unit = name + ".service"
assert mod.ORCHESTRATOR_HOME == main
assert mod.orchestrator_session_name() == main_mod.orchestrator_session_name() == name
assert mod.orchestrator_unit() == unit

# An actual child supplies the holder's PID, start time and namespace.
holder = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"])
try:
    lock.parent.mkdir(parents=True, exist_ok=True)
    lock.write_text(json.dumps(dict(pid=holder.pid, host=socket.gethostname(),
                                   created_at="2000-01-01T00:00:00+00:00",
                                   pid_start=mod.process_start(holder.pid),
                                   pid_ns=mod.pid_namespace(holder.pid))))
    original_lock = lock.read_bytes()
    assert mod.classify_orchestrator_lock().state == "held_verified"
    try:
        mod.acquire_orchestrator_lock()
        raise AssertionError("second holder was allowed")
    except mod.LockBusyError:
        pass

    # Refuse before a lock, identity change, service call or session is created.
    identity = git(linked, "config", "--get", "user.name")
    for root in (main, linked):
        result = cli(root, "recover")
        assert "orchestrator.lock: held" in result.stdout, result.stdout
    before_calls = calls.read_bytes() if calls.exists() else b""
    for force in ([], ["--force"]):
        result = cli(linked, "orchestrator", "run", *force, ok=False)
        assert result.returncode != 0 and str(main) in result.stderr, result
        assert "main checkout" in result.stderr, result.stderr
        assert lock.read_bytes() == original_lock and not local_lock.exists()
        assert (calls.read_bytes() if calls.exists() else b"") == before_calls
    assert git(linked, "config", "--get", "user.name") == identity
    print("ok - linked run refuses before side effects, including with --force")

    # The canonical record is live even when the linked store has a dead decoy.
    store = main / config.get("session_state_dir", ".nogging/state/sessions")
    store.mkdir(parents=True, exist_ok=True)
    record = store / f"{name}.json"
    rec = dict(name=name, role="orchestrator", bead_id=None, backend="tmux",
               state="running", floor_lifted=True, started_at=mod.now(),
               log_path=str(store / f"{name}.log"))
    record.write_text(json.dumps(rec))
    tmux_live.write_text(name + "\n")
    linked_store = linked / config.get("session_state_dir", ".nogging/state/sessions")
    linked_store.mkdir(parents=True, exist_ok=True)
    decoy = linked_store / f"{name}.json"
    decoy.write_text(json.dumps(dict(rec, state="stopped")))
    assert mod.orchestrator_live_session()[0] == record
    for root in (main, linked):
        result = cli(root, "orchestrator", "status")
        assert unit in result.stdout and f"lock:    held by {socket.gethostname()} pid {holder.pid}" in result.stdout, result.stdout
        assert f"session: {name} FULL-ACCESS running" in result.stdout, result.stdout
        result = cli(root, "doctor")
        assert unit in result.stdout and "orchestrator lock: held" in result.stdout, result.stdout
        assert str(holder.pid) in result.stdout and "a FULL-ACCESS session is live" in result.stdout, result.stdout
    assert lock.read_bytes() == original_lock
    print("ok - recover, status and doctor report the canonical holder, unit and live record")

    # Even an unreadable leftover must be ignored, and remain untouched.
    local_lock.parent.mkdir(parents=True, exist_ok=True)
    local_lock.write_text("not a lock record")
    for command in (("recover",), ("doctor",)):
        result = cli(linked, *command)
        assert "checkout-local orchestrator lock ignored" in result.stdout, result.stdout
        assert str(local_lock) in result.stdout, result.stdout
        assert "orchestrator.lock unreadable" not in result.stdout, result.stdout
    assert local_lock.read_text() == "not a lock record"
    assert lock.read_bytes() == original_lock
    print("ok - malformed worktree-local leftovers are reported and ignored")

    # Main checkout still guards a live holder. Stop/restart from a linked
    # checkout address the canonical unit, lock and session record only.
    try:
        main_mod.acquire_orchestrator_lock()
        raise AssertionError("main checkout accepted another holder")
    except main_mod.LockBusyError:
        pass
    cli(linked, "orchestrator", "restart")
    cli(linked, "orchestrator", "stop")
    assert json.loads(record.read_text())["state"] == "stopped"
    assert json.loads(decoy.read_text())["state"] == "stopped"
    assert not lock.exists() and local_lock.exists()
    service_calls = calls.read_text()
    for action in ("restart", "stop", "disable"):
        assert f"systemctl --user {action} {unit}" in service_calls, service_calls
    assert "nogg-orchestrator-different-worktree" not in service_calls
    print("ok - stop and restart from worktrees address canonical state")

    # Low-level acquire/release agree in both checkouts, not just the readers.
    acquired = mod.acquire_orchestrator_lock()
    assert acquired == lock and main_mod.classify_orchestrator_lock().state == "held_verified"
    main_mod.release_orchestrator_lock()
    assert not lock.exists() and local_lock.read_text() == "not a lock record"
    assert mod.classify_orchestrator_lock().state == "free"
    result = cli(linked, "orchestrator", "status")
    assert "lock:    free" in result.stdout, result.stdout
    print("ok - acquire and release use one canonical lock")

    # The public launch path uses the canonical singleton name as well.
    tmux_live.write_text("")
    result = cli(linked, "session", "launch", "--role", "orchestrator", "--agent", "claude",
                 "--profile", "orchestrator", "--prompt", "orchestrator")
    assert name in result.stdout, result.stdout
    assert tmux_live.read_text().strip() == name
    print("ok - session launch gives the orchestrator its canonical name")
finally:
    holder.terminate()
    holder.wait(timeout=5)

# Pure helper imports outside Git retain the existing current-root fallback.
scratch = work / "helper-root"
(scratch / ".nogging").mkdir(parents=True)
(scratch / ".nogging/config.json").write_text(json.dumps(config))
helper = load(scratch, "nogg_helper")
assert helper.ORCHESTRATOR_HOME == scratch
assert helper.orchestrator_unit() == "nogg-orchestrator-helper-root.service"
assert helper.acquire_orchestrator_lock() == scratch / ".nogging/locks/orchestrator.lock"
helper.release_orchestrator_lock()
print("ok - non-Git helper roots preserve their fallback")
PY
