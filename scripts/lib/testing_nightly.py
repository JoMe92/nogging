"""The decisions of `nogg test nightly` (test-policy-and-test-control, Decision 12):
the gates in their order, the record it leaves, and the digest item and `doctor`
lines read from that record. Pure: the caller passes the facts and does the work.

A restricted Lead can write the record, so it is no trust boundary: every reader goes
through `valid_record`, and the digest's own field rules still apply to what comes out.
"""
from __future__ import annotations

import re
from pathlib import Path

from session_dispatch import dedupe_key
from testing_ci import ABSENT, NONE, RAN

SCHEMA = 1
RECORD_FILE = "nightly-last.json"
LOG_FILE = "nightly-last.log"
LOG_PATH = ".nogging/state/testing/" + LOG_FILE
STAGE = "nightly"
KIND = "nightly_failed"
# No session owns this item; the digest needs a name of the session shape to hold it.
SESSION = "nightly"
NEXT_STEP = "./scripts/nogg doctor"
# The hour of the timer's last firing: it runs on a busy host, so a busy host still gets a run.
LAST_FIRING_HOUR = 5
FAILED_KEPT = 5
MAX_TEXT = 200
PASSED, FAILED = "passed", "failed"
FULL_STEP, SETUP_STEP, WORKTREE_STEP = "full", "setup", "worktree"
STEPS = (FULL_STEP, SETUP_STEP, WORKTREE_STEP)
_CONTROL = re.compile(r"[\x00-\x1f\x7f]+")
_RUNNER_FAILURE = re.compile(r"^FAIL - (\S.*)$")


def worktree_path(main):
    """The retained worktree: `<main>-nightly`, a sibling like every Nogging worktree."""
    main = Path(main)
    return main.parent / f"{main.name}-nightly"


def quiet_exit(enabled, supervised):
    """Why this firing ends at once, leaving nothing behind, or None."""
    if not enabled:
        return "testing.nightly.enabled is false"
    if supervised:
        return "a supervised session does not run the nightly suite"
    return None


def ci_skip(kind):
    """Why a CI result ends this firing, or None. `unknown` runs: the operator enabled
    the timer, and a run nobody needed costs less than a night nothing tested."""
    return "CI runs the tests" if kind == RAN else None


def tested_skip(record, head):
    """Why this commit needs no run, or None. A failed commit counts too: a nightly run
    happens at most once per commit, and the failure stays reported until a later pass."""
    if record and record.get("head") == head:
        return f"{head[:12]} was already tested ({record['status']})"
    return None


def busy_reason(load, cores, held):
    """Why the host is too busy, or None: the 1-minute load above half the core count,
    or a heavy slot held by anything."""
    if load > cores / 2:
        return f"load {load:.2f} above half of {cores} cores"
    if held:
        return f"a heavy test slot is held by {', '.join(held)}"
    return None


def deferral(load, cores, held, hour):
    """Why this firing waits for the next one, or None. The last firing never waits."""
    return None if hour == LAST_FIRING_HOUR else busy_reason(load, cores, held)


def failed_from_log(lines):
    """The first failed test names in the `FAIL - <test>` lines of `scripts/test`, the
    runner that writes no JUnit. `lines` is any iterable: a full suite's log is large."""
    names = []
    for line in lines:
        match = _RUNNER_FAILURE.match(line)
        if match:
            names.append(match.group(1).strip())
            if len(names) == FAILED_KEPT:
                break
    return names


def _clean(value):
    return _CONTROL.sub(" ", str(value)).strip()[:MAX_TEXT]


def build_record(*, run_id, at, status, head, seconds, log=None, failed=(), offline=False, step=FULL_STEP):
    """One `nightly-last.json`: `step` says how far the run got, `offline` that the
    fetch failed and it tested the last known commit."""
    return {"schema": SCHEMA, "run_id": run_id, "at": at, "status": status, "head": head,
            "seconds": round(seconds, 3), "log": log, "failed": [_clean(name) for name in failed][:FAILED_KEPT],
            "offline": bool(offline), "step": step}


def valid_record(value):
    """A clean copy of a record read back, or None when it holds no usable run."""
    if not isinstance(value, dict) or value.get("schema") != SCHEMA or value.get("status") not in (PASSED, FAILED):
        return None
    texts = {key: value.get(key) for key in ("run_id", "at", "head")}
    if not all(isinstance(field, str) and field for field in texts.values()):
        return None
    seconds, log, failed = value.get("seconds"), value.get("log"), value.get("failed")
    failed = failed if isinstance(failed, list) else []
    return {"schema": SCHEMA, "status": value["status"], **{key: _clean(field) for key, field in texts.items()},
            "seconds": seconds if type(seconds) in (int, float) and seconds >= 0 else None,
            "log": _clean(log) if isinstance(log, str) and log else None,
            "failed": [_clean(name) for name in failed if isinstance(name, str)][:FAILED_KEPT],
            "offline": value.get("offline") is True,
            "step": value.get("step") if value.get("step") in STEPS else FULL_STEP}


def _summary(record):
    """The failure in one line, the log first: a digest shows only the start of a field."""
    parts = [f"log {record['log']}"] if record["log"] else []
    if record["step"] != FULL_STEP:
        parts.append(f"the {record['step']} step failed, no test ran")
    elif record["failed"]:
        parts.append("failed: " + ", ".join(record["failed"]))
    if record["offline"]:
        parts.append("offline: last known commit")
    return "; ".join(parts) or "see nogg doctor"


def digest_action(record):
    """The queue action for a failed record, or None for anything else. Each dispatch
    pass derives it again; the key holds the run, so repeats are one item and a later
    pass clears it."""
    if not record or record["status"] != FAILED:
        return None
    key, reason = dedupe_key(SESSION, KIND, record["run_id"]), f"nightly run failed: {_summary(record)}"
    return {"type": "queue", "session": SESSION, "key": key, "reason": reason,
            "item": {"key": key, "kind": KIND, "session": SESSION, "bead": None, "pr": None, "ci": None,
                     "diff": None, "head": record["head"][:12], "reason": reason, "next": NEXT_STEP}}


def doctor_lines(record, ci_kind, timer):
    """(warnings, notes) from the last record and the CI result. Nothing here changes
    `doctor`'s exit code: a failure is shown with dispatch off too, and the timer is
    named only where nothing else tests the branch and it has never run."""
    if record:
        if record["status"] != FAILED:
            return [], []
        return [f"nightly: the run of {record['head'][:12]} at {record['at']} failed: {_summary(record)}"], []
    if ci_kind in (NONE, ABSENT):
        return [], [f"nightly: no run is recorded; enable the timer: `systemctl --user link "
                    f"\"$PWD/systemd/{timer}.service\" && systemctl --user enable --now "
                    f"\"$PWD/systemd/{timer}.timer\"`"]
    return [], []
