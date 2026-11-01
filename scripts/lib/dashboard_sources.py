"""Effects of `nogg dashboard`: the `bd`, session and test loaders.

Each reader returns the snapshot of the data contract (design Decision 9), already
passed through the allow-lists of `dashboard_model`, so the process never holds a raw
Bead or session record. A reader runs on the refresher thread only. A request never
calls one.

Every `bd` call is `bd --readonly --sandbox …` with a 30 second timeout, and runs with
`BEADS_DOLT_AUTO_START=0`, so a call can never start Dolt. A failure is classified
(`dolt_unreachable`, `bd_absent`, `bd_error`) and raised as `SourceError`: stderr text
decides the class and is dropped, so it can never reach a client.
"""
from __future__ import annotations

import json, os, re, subprocess
from pathlib import Path

import dashboard_cache as cache
import dashboard_model as model

BD_TIMEOUT = 30
BEAD_STATUSES = "open,in_progress,blocked,deferred,closed"
DOLT_DOWN = re.compile(r"(?i)connection refused|can'?t connect|cannot connect|unable to connect|dial tcp|"
                       r"server (?:is )?not running|not reachable|unreachable|no such host|"
                       r"failed to connect")
SourceError = cache.SourceError


def classify(stderr):
    """The failure class of a non-zero `bd` exit. The text decides it and is then dropped."""
    return "dolt_unreachable" if DOLT_DOWN.search(stderr or "") else "bd_error"


def bd_json(command, args, home, run=subprocess.run, timeout=BD_TIMEOUT):
    """The parsed JSON output of `bd --readonly --sandbox <args>`, run in `home`."""
    argv = [*([command] if isinstance(command, str) else command), "--readonly", "--sandbox", *args]
    env = {**os.environ, "BEADS_DOLT_AUTO_START": "0", "GIT_OPTIONAL_LOCKS": "0", "DOLT_DISABLE_EVENT_FLUSH": "1"}
    try:
        done = run(argv, cwd=home, env=env, encoding="utf-8", errors="replace", capture_output=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        raise SourceError("bd_absent") from None
    except (subprocess.TimeoutExpired, OSError):
        raise SourceError("bd_error") from None
    if done.returncode:
        raise SourceError(classify(done.stderr))
    try:
        return json.loads(done.stdout or "null")
    except (ValueError, RecursionError):
        raise SourceError("bd_error") from None


def _ids(value):
    """Bead IDs of a `bd` answer: a list of ID strings or of objects carrying `id`."""
    found = []
    for item in value if isinstance(value, list) else ():
        identifier = item.get("id") if isinstance(item, dict) else item
        if isinstance(identifier, str) and model.BEAD_ID.fullmatch(identifier):
            found.append(identifier)
    return found


def _cycles(value):
    """Cycles as lists of IDs, whatever way `bd dep cycles` nests them."""
    return [ids for ids in (_ids(cycle) for cycle in value if isinstance(cycle, list)) if ids] \
        if isinstance(value, list) else []


def read_beads(beads_command, home, run=subprocess.run):
    """{"beads": [...], "ready": [...], "cycles": [[...]]}. Any failing call fails the
    source: a missing `ready` would show wrong flags rather than an honest gap."""
    listing = bd_json(beads_command, ["list", "--status", BEAD_STATUSES, "--limit", "0", "--json"], home, run)
    ready = bd_json(beads_command, ["ready", "--limit", "0", "--json"], home, run)
    cycles = bd_json(beads_command, ["dep", "cycles", "--json"], home, run)
    if not isinstance(listing, list):
        raise SourceError("bd_error")
    beads = [bead for bead in map(model.allow_bead, listing) if bead]
    return {"beads": beads, "ready": _ids(ready), "cycles": _cycles(cycles)}


def read_sessions(records):
    """{"sessions": [...], "floor": <iso|None>} from session records. No record at all
    reads as `absent`: records are local to this host."""
    sessions = [item for item in map(model.allow_session, records) if item]
    if not sessions:
        raise cache.Absent()
    sessions.sort(key=lambda item: (item["started_at"] or "", item["name"]))
    starts = [item["started_at"] for item in sessions if item["started_at"]]
    return {"sessions": sessions, "floor": min(starts) if starts else None}


def read_tests(records):
    """{"records": [...], "stage_seconds": {...}, "floor": <iso|None>} from the `nogg test`
    run records. No record reads as `absent`: a consumer repository may keep none."""
    kept = [item for item in map(model.allow_test_record, records) if item]
    if not kept:
        raise cache.Absent()
    kept.sort(key=lambda item: item["at"] or "")
    times = [item["at"] for item in kept if item["at"]]
    return {"records": kept, "stage_seconds": model.stage_seconds(kept),
            "floor": min(times) if times else None}


# --- change gates -----------------------------------------------------------------

def _stat(path):
    try:
        info = os.stat(path)
    except OSError:
        return None
    return (info.st_mtime_ns, info.st_size)


def directory_gate(directory):
    """A cheap token that changes when files in `directory` come, go or are replaced.
    It only stats; it never creates anything."""
    return lambda: _stat(Path(directory))


def files_gate(*paths):
    """A token of the size and mtime of each file, for the test records and their rotation."""
    return lambda: tuple(_stat(path) for path in paths)
