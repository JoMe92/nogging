#!/usr/bin/env bash
# The dashboard's Git and token sources against the real thing: a scratch Git repository,
# and a scratch Dolt usage store with a real Collector. The second half is the proof of the
# read lease (design Decision 8), so it needs `dolt`, and it never touches a live store. It
# reports a visible skip where `dolt` is not installed; the lease's lock behaviour without
# Dolt is in scripts/lib/token_usage_store_test.py. Waits are on states, with a deadline.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
if [[ ! -f "$root/scripts/lib/dashboard_usage_test.py" ]]; then
  echo "ok   - dashboard-usage skipped (installed consumer copy)"
  exit 0
fi
PYTHONDONTWRITEBYTECODE=1 python3 - "$root" <<'PY'
from pathlib import Path
import datetime as dt, hashlib, json, os, select, shutil, signal, subprocess, sys, tempfile, threading, time
import urllib.request

source = Path(sys.argv[1])
sys.path.insert(0, str(source / "scripts/lib"))
import dashboard_cache as cache
import dashboard_slow_sources as slow
import token_usage_collect as collect
import token_usage_report as report
from token_usage_store import Store, StoreUnavailable

failures = []
REAL_DOLT = shutil.which("dolt")
LEASED_READ = "SELECT SLEEP(3)"
OPEN_READ_SECONDS = 60
FORBIDDEN = ("device_id", "hostname", "dev-1")


def check(name, condition, detail=""):
    print(f"{'ok  ' if condition else 'FAIL'} - {name}" + (f": {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(name)


def until(predicate, seconds=20):
    """The first true value of `predicate`, or its last value at the deadline."""
    deadline, tick = time.monotonic() + seconds, threading.Event()
    value = predicate()
    while not value and time.monotonic() < deadline:
        tick.wait(0.01)
        value = predicate()
    return value


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def dolt_calls():
    return LOG.read_text().splitlines() if LOG.exists() else []


def reader_holds_the_store(call):
    """The PID of the logged Dolt call `call` once it has the store open."""
    def found():
        for line in dolt_calls():
            pid, _, argv = line.partition(" ")
            if call in argv:
                try:
                    return int(pid) if any("noms" in os.readlink(fd) for fd in Path(f"/proc/{pid}/fd").iterdir()) else None
                except OSError:
                    return None
        return None
    return until(found)


def usage(number, seg="seg-1", bead_time="2026-11-01T10:30:00Z"):
    return ("usage_events", dict(source_id="claude:conv", event_id=f"e{number}", revision="v1", source_ordinal=number,
                                 source_timestamp=bead_time, segment_id=seg, runtime="claude", model="a-model",
                                 input_tokens=100, cache_read_tokens=40, cache_write_tokens=0, output_tokens=7,
                                 semantics=["cache_summed_input"], completeness="complete"))


SEED = [("session_segments", dict(source_id="nogg-session:seg-1", event_id="segment", revision="v1", source_ordinal=0,
                                  source_timestamp="2026-11-01T10:00:00Z", runtime="claude", supervised_id="lead-1",
                                  device_id="dev-1")),
        ("attribution_events", dict(source_id="nogg-session:seg-1", event_id="boundary:0", revision="v1", source_ordinal=0,
                                    source_timestamp="2026-11-01T10:00:00Z", segment_id="seg-1", bead_id="SPEC-aaaa",
                                    complexity="standard"))] + [usage(n) for n in range(3)]


def scratch_store(name):
    target = TMP / name
    shutil.copytree(TEMPLATE, target)
    return Store(target, lambda _: {"state_dir": str(target)})


def spool(store, numbers):
    collector = collect.Collector(store)
    for number in numbers:
        collector._write(collector._dir("spool") / f"{number:020d}-batch.json",
                         {"records": [list(usage(number))], "owners": {}})
    return collector


def attempts(collector):
    return collector._read(collector.root / "attempts.json", {})


def read(store):
    return slow.read_tokens(lambda: store, lambda: report)


def fingerprint(directory):
    return sorted((str(path.relative_to(directory)), hashlib.sha256(path.read_bytes()).hexdigest())
                  for path in directory.rglob("*") if path.is_file())


def facts_of(store):
    return store.current_counts()["usage_events"]


def open_read():
    """A read that stays open until it is killed, so a writer's fate cannot depend on how
    long the read happened to last."""
    return f"SELECT SLEEP({OPEN_READ_SECONDS})"


def stop_read(pid):
    """Kill the Dolt read that the shim logged, and nothing else."""
    if type(pid) is not int or pid <= 1:
        raise ValueError(f"not a Dolt reader: {pid!r}")
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def drain_beside_an_unleased_read(collector, store):
    """The control: a real drain against a real open read that holds no lease."""
    def reader():
        try:
            store._dolt("sql", "-q", open_read(), timeout=OPEN_READ_SECONDS + 30)
        except StoreUnavailable:
            pass                       # killed below, once the drain has its answer
    LOG.unlink(missing_ok=True)
    thread = threading.Thread(target=reader)
    thread.start()
    pid = reader_holds_the_store(open_read())
    check("the unleased read has the store open", pid is not None)
    result = collector.drain(60)
    stop_read(pid)
    thread.join(30)
    return result


def drain_during_a_leased_read(collector, store):
    """A real drain started during a real read under the lease. It returns the drain's
    result, and what could be seen as the read ended and before the lease went."""
    outcome, seen = {}, {}

    def reader():
        with store.read_lease():
            store._dolt("sql", "-q", LEASED_READ)
            seen.update(writer_alive=writer.is_alive(), calls=dolt_calls())

    def drain():
        outcome["result"] = collector.drain(60)
    writer = threading.Thread(target=drain)
    thread = threading.Thread(target=reader)
    LOG.unlink(missing_ok=True)
    thread.start()
    check("the leased read has the store open", reader_holds_the_store(LEASED_READ) is not None)
    writer.start()
    thread.join(30)
    writer.join(60)
    return outcome.get("result"), seen


with tempfile.TemporaryDirectory(prefix="nogg usage ") as tmp:
    TMP = Path(tmp)
    LOG = TMP / "dolt-calls"
    shim = TMP / "bin"
    shim.mkdir()
    # Every Dolt call is logged with its PID, and runs real Dolt where there is one.
    (shim / "dolt").write_text('#!/bin/sh\necho "$$ $*" >> "%s"\n%s\n' % (
        LOG, f'exec "{REAL_DOLT}" "$@"' if REAL_DOLT else "exit 127"))
    (shim / "dolt").chmod(0o755)
    os.environ["PATH"] = f"{shim}{os.pathsep}{os.environ['PATH']}"
    os.environ.update(DOLT_DISABLE_EVENT_FLUSH="1", GIT_OPTIONAL_LOCKS="0", GIT_CONFIG_GLOBAL=os.devnull,
                      GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="Fixture", GIT_COMMITTER_NAME="Fixture",
                      GIT_AUTHOR_EMAIL="fixture@example.invalid", GIT_COMMITTER_EMAIL="fixture@example.invalid")

    # --- The Git source on a real repository ---------------------------------------------
    repo = TMP / "repo"
    repo.mkdir()
    def git(*args):
        return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()
    def commit(subject, name, lines):
        (repo / name).write_text("line\n" * lines)
        git("add", "-A")
        git("commit", "-qm", subject)
        return git("rev-parse", "HEAD")
    git("init", "-qb", "develop")
    commit("chore: seed", "README.md", 1)
    first = commit("feat: one [SPEC-aaaa]", "one.py", 3)

    reads = []
    def read_git():
        reads.append(1)
        return slow.read_git(repo, numstat=numstat)
    numstat, clock = {}, Clock()
    refresher = cache.Refresher({"git": read_git}, {"git": slow.git_gate(repo)}, clock=clock)
    refresher.touch()
    refresher.step()
    snapshot = refresher.snapshot("git")
    check("the Git source reads a real repository",
          [(c["sha"], c["beads"], c["production_lines"]) for c in snapshot["commits"]] == [(first, ["SPEC-aaaa"], 3)]
          and snapshot["tokenless_commits"] == 1 and snapshot["root_commit_at"] is not None, str(snapshot))

    # Scenario "Nothing changed".
    clock.now += cache.INTERVALS["git"] + 1
    refresher.touch()
    refresher.step()
    check("unchanged refs skip the reload", len(reads) == 1, str(reads))
    git("update-ref", "refs/dolt/data", first)
    git("update-ref", "refs/nogg/backup", first)
    clock.now += cache.INTERVALS["git"] + 1
    refresher.touch()
    refresher.step()
    check("a ref the source does not walk skips the reload", len(reads) == 1, str(reads))
    second = commit("feat: two [SPEC-aaaa]", "two.py", 4)
    clock.now += cache.INTERVALS["git"] + 1
    refresher.touch()
    refresher.step()
    check("a new commit reloads the source",
          len(reads) == 2 and second in [c["sha"] for c in refresher.snapshot("git")["commits"]])
    check("line counts stay cached per commit", set(numstat) == {first, second})

    # --- A repository without a store, through the real command --------------------------
    consumer = TMP / "consumer"
    consumer.mkdir()
    subprocess.run(["bash", str(source / "scripts/lib/test-fixture-config.sh"), str(source / ".nogging/config.json"),
                    str(consumer / ".nogging/config.json")], check=True)
    config = json.loads((consumer / ".nogging/config.json").read_text())
    config["beads_command"] = str(TMP / "no-such-bd")
    (consumer / ".nogging/config.json").write_text(json.dumps(config, indent=2) + "\n")
    (consumer / ".gitignore").write_text(".nogging/state/\n.nogging/locks/\n")
    subprocess.run(["git", "init", "-qb", "develop", str(consumer)], check=True)
    subprocess.run(["git", "-C", str(consumer), "add", "."], check=True)
    subprocess.run(["git", "-C", str(consumer), "commit", "-qm", "feat: seed [SPEC-bbbb]"], check=True)
    LOG.unlink(missing_ok=True)
    process = subprocess.Popen([sys.executable, str(source / "scripts/nogg"), "dashboard", "--port", "0"], text=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=consumer,
                               env={**os.environ, "NOGGING_ROOT": str(consumer)})
    ready, _, _ = select.select([process.stdout], [], [], 30)
    line = process.stdout.readline() if ready else ""
    port = int(line.split("http://127.0.0.1:")[1].split("/")[0]) if "127.0.0.1:" in line else None
    check("the command starts in a repository without a store", port is not None, line)
    states = {}
    def settled():
        global states
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/api/v1/freshness", timeout=5) as reply:
            states = {k: v["state"] for k, v in json.loads(reply.read())["data"].items()}
        return all(states.get(name) not in (None, "loading", "refreshing") for name in ("git", "tokens"))
    until(settled)
    check("without a store the token source is absent and Git still reads",
          states.get("tokens") == "absent" and states.get("git") == "fresh", str(states))
    check("no Dolt call ran without a store", dolt_calls() == [], str(dolt_calls()))
    process.send_signal(signal.SIGTERM)
    process.wait(timeout=20)
    process.stdout.close()
    check("no directory or lock was created", not (consumer / ".nogging/state/token-usage").exists())

    # --- A collection is running: no Dolt at all -----------------------------------------
    busy_state = TMP / "busy"
    busy = Store(busy_state, lambda _: {"state_dir": str(busy_state)})
    with busy.locked():
        (busy.database / ".dolt").mkdir(parents=True)
        LOG.unlink(missing_ok=True)
        try:
            read(busy)
            outcome = "read"
        except cache.Busy:
            outcome = "busy"
    check("a held lock makes the source busy", outcome == "busy", outcome)
    check("a busy source touches no Dolt", dolt_calls() == [], str(dolt_calls()))

    if not REAL_DOLT:
        print("SKIP - real Dolt proof of the read lease: `dolt` is not installed")
    else:
        TEMPLATE = TMP / "template"
        TEMPLATE.mkdir()
        template = Store(TEMPLATE, lambda _: {"state_dir": str(TEMPLATE)})
        template.initialize()
        template.device()
        template.append(SEED)

        # The control: without the lease the collision is real, and costs an attempt.
        store = scratch_store("control")
        collector = spool(store, [10])
        result = drain_beside_an_unleased_read(collector, store)
        check("control: without a lease a running read fails the import",
              result[1] is not None and attempts(collector), f"{result} {attempts(collector)}")
        check("control: the batch stayed pending", collector.pending()["spooled_batches"] == 1)

        # Scenario "A collection starts during a read".
        store = scratch_store("lease")
        collector = spool(store, [10, 11])
        before = facts_of(store)
        result, seen = drain_during_a_leased_read(collector, store)
        check("the collector waited through the whole read, before any Dolt call of its own",
              seen.get("writer_alive") is True and len(seen.get("calls", ())) == 1, str(seen))
        check("no batch failed because of the read", result == (2, None) and attempts(collector) == {}, str(result))
        check("the waiting batches were imported, none quarantined",
              collector.pending() == {"spooled_batches": 0, "quarantined_batches": 0} and facts_of(store) == before + 2)

        # A reader killed mid-read: its Dolt child lives on and must keep the writer out.
        store = scratch_store("killed")
        collector = spool(store, [10])
        LOG.unlink(missing_ok=True)
        holder = subprocess.Popen([sys.executable, "-c", """
import sys
sys.path.insert(0, sys.argv[1])
from pathlib import Path
from token_usage_store import Store
state = Path(sys.argv[2])
store = Store(state, lambda _: {'state_dir': str(state)})
with store.read_lease():
    store._dolt('sql', '-q', sys.argv[3], timeout=float(sys.argv[4]))
""", str(source / "scripts/lib"), str(store.root.parent), open_read(), str(OPEN_READ_SECONDS + 30)])
        orphan = reader_holds_the_store(open_read())
        check("the read has the store open", orphan is not None)
        holder.send_signal(signal.SIGKILL)
        holder.wait()
        outcome = {}
        writer = threading.Thread(target=lambda: outcome.update(result=collector.drain(60)))
        writer.start()
        writer.join(1.5)
        check("while the orphaned Dolt read runs, the collector waits",
              writer.is_alive() and len(dolt_calls()) == 1, f"{outcome} {dolt_calls()}")
        stop_read(orphan)
        writer.join(60)
        check("a reader killed mid-read fails no import",
              outcome.get("result") == (1, None) and attempts(collector) == {}, str(outcome))

        # Scenario "Pending usage stays pending".
        store = scratch_store("pending")
        collector = spool(store, [20, 21])
        spooled, before = fingerprint(store.root / "collector"), facts_of(store)
        snapshot = read(store)
        check("the pending count is shown", snapshot["pending_batches"] == 2, str(snapshot.get("pending_batches")))
        check("a read leaves the spool unchanged", fingerprint(store.root / "collector") == spooled)
        check("a read imports nothing", facts_of(store) == before)

        # The whole source through the refresher: gate, busy and the contract.
        store = scratch_store("source")
        status = store.root / "collector/status.json"
        status.parent.mkdir(parents=True, exist_ok=True)
        status.write_text(json.dumps({"last_success_at": "first"}))
        clock = Clock()
        refresher = cache.Refresher({"tokens": lambda: read(store)}, {"tokens": slow.tokens_gate(lambda: store)}, clock=clock)
        refresher.touch()
        refresher.step()
        snapshot = refresher.snapshot("tokens")
        check("the snapshot keeps the contract",
              sorted(snapshot) == ["by_bead", "by_day", "by_model", "floors", "partial", "pending_batches"], str(snapshot))
        check("the fresh input is the input without cache reads",
              snapshot["by_bead"]["SPEC-aaaa"]["tokens"]["fresh_input_tokens"] == 180
              and snapshot["by_day"]["2026-11-01"]["claude"]["tokens"]["output_tokens"] == 21
              and snapshot["by_model"]["a-model"]["tokens"]["output_tokens"] == 21, str(snapshot))
        check("no identity reaches the snapshot", not any(word in json.dumps(snapshot) for word in FORBIDDEN))

        LOG.unlink(missing_ok=True)
        clock.now += cache.INTERVALS["tokens"] + 1
        refresher.touch()
        refresher.step()
        check("an unchanged last_success_at skips the reload", dolt_calls() == [], str(dolt_calls()))

        status.write_text(json.dumps({"last_success_at": "second"}))
        clock.now += cache.INTERVALS["tokens"] + 1
        refresher.touch()
        with store.locked():
            refresher.step()
        item = refresher.status()["tokens"]
        check("a running collection leaves the source stale and keeps its data",
              item["state"] == "stale" and item.get("reason") == "busy" and refresher.snapshot("tokens") == snapshot, str(item))
        check("that refresh touched no Dolt", dolt_calls() == [], str(dolt_calls()))
        clock.now += cache.BUSY_RETRY + 1
        refresher.touch()
        refresher.step()
        check("a later tick reads again", refresher.status()["tokens"]["state"] == "fresh" and dolt_calls() != [])

print("FAILED: " + ", ".join(failures) if failures else "all dashboard-usage checks passed")
sys.exit(1 if failures else 0)
PY
