#!/usr/bin/env bash
# `nogg dashboard` serving live data as an operator runs it: a real process in a scratch
# repository, a stub `bd`, and records written where the main checkout keeps them.
# Request handling and the refresher are in scripts/lib/dashboard_*_test.py. Offline: port
# 0, no Dolt, no real `bd`. The process is waited on by its state, with a bounded deadline.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
if [[ ! -f "$root/scripts/lib/dashboard_data_test.py" ]]; then
  echo "ok   - dashboard-data skipped (installed consumer copy)"
  exit 0
fi
PYTHONDONTWRITEBYTECODE=1 python3 - "$root" <<'PY'
from pathlib import Path
import json, os, select, signal, subprocess, sys, tempfile, threading, time, urllib.request

source = Path(sys.argv[1])
nogg = source / "scripts/nogg"
failures = []
STUB = """#!/bin/sh
echo "$(pwd)|$BEADS_DOLT_AUTO_START|$*" >> "$STUB_DIR/calls"
case "$*" in
  *"list"*) echo '[{"id":"SPEC-aaaa","title":"A title","status":"open","labels":["openspec:change:demo"],"owner":"%s"}]' ;;
  *"ready"*) echo '[{"id":"SPEC-aaaa"}]' ;;
  *) echo '[]' ;;
esac
""" % ("someone" + "@" + "example.com")


def check(name, condition, detail=""):
    print(f"{'ok  ' if condition else 'FAIL'} - {name}" + (f": {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(name)


def repository(path, beads_command):
    path.mkdir(parents=True)
    subprocess.run(["bash", str(source / "scripts/lib/test-fixture-config.sh"), str(source / ".nogging/config.json"),
                    str(path / ".nogging/config.json")], check=True)
    config = json.loads((path / ".nogging/config.json").read_text())
    config["beads_command"] = str(beads_command)
    (path / ".nogging/config.json").write_text(json.dumps(config, indent=2) + "\n")
    (path / ".gitignore").write_text(".nogging/state/\n.nogging/locks/\n")
    subprocess.run(["git", "init", "-q", str(path)], check=True)
    subprocess.run(["git", "-C", str(path), "add", "."], check=True)
    subprocess.run(["git", "-C", str(path), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                    "commit", "-qm", "seed"], check=True)
    return path


def start(repo, stub_dir):
    process = subprocess.Popen([sys.executable, str(nogg), "dashboard", "--port", "0"], text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=repo,
                               env={**os.environ, "NOGGING_ROOT": str(repo), "STUB_DIR": str(stub_dir)})
    ready, _, _ = select.select([process.stdout], [], [], 30)
    line = process.stdout.readline() if ready else ""
    return process, int(line.split("http://127.0.0.1:")[1].split("/")[0]) if "127.0.0.1:" in line else None


def api(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as reply:
        return json.loads(reply.read())


def settled(port, wanted, seconds=30):
    """The freshness document once every named source has left `loading`, or the last one."""
    deadline, doc = time.monotonic() + seconds, None
    gate = threading.Event()
    while time.monotonic() < deadline:
        doc = api(port, "/api/v1/freshness")
        if all(doc["data"].get(name, {}).get("state") not in (None, "loading", "refreshing") for name in wanted):
            return doc
        gate.wait(0.05)
    return doc


def stop(process):
    process.send_signal(signal.SIGTERM)
    code = process.wait(timeout=20)
    process.stdout.close()
    return code


def state_files(repo):
    base = repo / ".nogging/state"
    return sorted(str(p.relative_to(base)) for p in base.rglob("*") if p.is_file()) if base.exists() else []


with tempfile.TemporaryDirectory(prefix="nogg data ") as tmp:
    tmp = Path(tmp)
    stub_dir = tmp / "stub"
    stub_dir.mkdir()
    bd = stub_dir / "bd"
    bd.write_text(STUB)
    bd.chmod(0o755)
    repo = repository(tmp / "main", bd)

    # The main checkout keeps one session record and one test record.
    sessions = repo / ".nogging/state/sessions"
    sessions.mkdir(parents=True)
    (sessions / "lead.json").write_text(json.dumps(
        {"name": "lead-1", "bead_id": "SPEC-aaaa", "role": "lead", "state": "ended", "agent": "claude",
         "started_at": "2026-11-01T10:00:00Z", "ended_at": "2026-11-01T11:00:00Z", "exit_reason": "done\nmore",
         "command": ["claude"], "working_dir": "/home/someone/work"}))
    testing = repo / ".nogging/state/testing"
    testing.mkdir(parents=True)
    (testing / "runs.jsonl").write_text(json.dumps(
        {"schema": 1, "at": "2026-11-01T10:30:00+00:00", "id": "r1", "stage": "bead", "bead": "SPEC-aaaa",
         "status": "passed", "exit": 0, "over_budget": False, "seconds": 12.5}) + "\n")
    linked = tmp / "linked"
    subprocess.run(["git", "-C", str(repo), "worktree", "add", "-q", "-b", "linked", str(linked)], check=True)
    before = state_files(repo)

    # It runs from a linked worktree: records and Beads of the canonical checkout. Wait for
    # all five sources: the refresher runs Git in the background, and the child check below
    # asks whether a request left a process, not whether the refresher is busy.
    process, port = start(linked, stub_dir)
    check("a linked worktree starts it", port is not None)
    doc = settled(port, ["beads", "sessions", "tests", "git", "tokens"])
    states = {name: item["state"] for name, item in doc["data"].items()}
    check("a linked worktree reads the sessions, tests and Beads of the main checkout",
          states.get("beads") == states.get("sessions") == states.get("tests") == "fresh", str(states))
    check("the linked worktree has no state of its own", not (linked / ".nogging/state").exists())
    calls = (stub_dir / "calls").read_text().splitlines()
    check("bd ran in the main checkout, read-only, without auto-start",
          calls and all(line.split("|")[0] == str(repo.resolve()) and line.split("|")[1] == "0"
                        and "--readonly --sandbox" in line for line in calls), str(calls))
    beads = api(port, "/api/v1/beads")
    check("the list is served from the stub", [item["id"] for item in beads["data"]["beads"]] == ["SPEC-aaaa"])
    raw = json.dumps(beads) + json.dumps(api(port, "/api/v1/changes")) + json.dumps(doc)
    check("no owner address reaches a response", "example.com" not in raw and "someone" not in raw, raw[:200])
    check("no child process lingers after a request", not [
        child for task in Path(f"/proc/{process.pid}/task").iterdir() for child in (task / "children").read_text().split()])
    check("SIGTERM ends it cleanly", stop(process) == 0)
    check("it created no file in the main checkout", state_files(repo) == before, str(state_files(repo)))

    # A repository without bd: the server starts, the Bead source says why, and the rest works.
    plain = repository(tmp / "plain", tmp / "no-such-bd")
    process, port = start(plain, stub_dir)
    check("a repository without bd still starts", port is not None)
    doc = settled(port, ["beads", "sessions", "tests"])
    check("the Bead source reports bd as missing",
          doc["data"]["beads"]["state"] == "unavailable" and doc["data"]["beads"].get("reason") == "bd_absent",
          str(doc["data"]))
    check("the other sources are absent, not zero",
          doc["data"].get("sessions", {}).get("state") == "absent" and doc["data"].get("tests", {}).get("state") == "absent",
          str(doc["data"]))
    check("the shell still loads", b"<html" in urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=5).read().lower())
    check("it created no state", state_files(plain) == [], str(state_files(plain)))
    check("SIGTERM ends it cleanly without bd", stop(process) == 0)

print("FAILED: " + ", ".join(failures) if failures else "all dashboard-data checks passed")
sys.exit(1 if failures else 0)
PY
