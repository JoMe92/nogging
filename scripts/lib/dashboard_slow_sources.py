"""Effects of `nogg dashboard`: the Git and token loaders.

Each reader returns the snapshot of the data contract (design Decision 9) and runs on
the refresher thread only, so a request never calls one. Both sources are slow and read
in the background behind a change gate: the Git source behind a hash of the refs, the
token source behind the collector's `last_success_at`.

A token read holds `Store.read_lease()` for all of its Dolt calls, so a collection that
starts during the read waits instead of failing an import, and a read never starts while
a collection is inside. `Collector` is not used: its `_dir()` creates directories, and
the dashboard adds no state. Raw facts leave memory once they are reduced.
"""
from __future__ import annotations

import datetime as dt, hashlib, json, re, subprocess, time

import dashboard_cache as cache
import dashboard_model as model
import token_usage_report as report

GIT_TIMEOUT = 60            # seconds per Git call; the first read walks the whole history
TOKEN_READ_CAP = 45.0       # seconds for all the Dolt calls of one read together
REFS = ("for-each-ref", "--format=%(objectname) %(refname)", "refs/heads", "refs/remotes", "refs/tags")
BEAD_SHAPE = re.compile(r"[A-Za-z][A-Za-z0-9_-]*-[A-Za-z0-9.]+")

# {sha: line counts}. A commit never changes, so a later read asks Git only for new ones.
# Held in this process's memory only; the refresher is its one user.
_numstat = {}


class BeadShaped:
    """The set of subject tokens shaped like a Bead ID. The Git source reads without
    the Bead list, and `[wip]` must not count as an attributed commit."""

    def __contains__(self, token):
        return bool(BEAD_SHAPE.fullmatch(token) and model.BEAD_ID.fullmatch(token))


def _utc(epoch):
    return model.utc_iso(dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat())


def git_gate(home, run=subprocess.run):
    """A hash of the refs that the Git source walks, or None when Git cannot answer. Any
    other ref (Dolt's, a backup) moves without causing a reload."""
    git = report._git_runner(home, GIT_TIMEOUT, run)

    def gate():
        listing = git(*REFS)
        return hashlib.sha256(listing.encode()).hexdigest() if listing else None
    return gate


def read_git(home, run=subprocess.run, numstat=None):
    """The `git` snapshot. A repository with no ref at all reads as `absent`."""
    git = report._git_runner(home, GIT_TIMEOUT, run)
    listing = git(*REFS)
    if listing is None:
        raise cache.SourceError("error")
    if not listing.strip():
        raise cache.Absent()
    found = report.bead_commits(home, BeadShaped(), GIT_TIMEOUT, run, _numstat if numstat is None else numstat)
    roots = git("log", "--branches", "--remotes", "--tags", "--max-parents=0", "--format=%at")
    if found is None or roots is None:
        raise cache.SourceError("error")
    commits = sorted(({**commit, "at": _utc(commit["at"]), "subject": model.scrub(commit["subject"])}
                      for commit in found["commits"]), key=lambda commit: (commit["at"], commit["sha"]))
    times = [int(line) for line in roots.split()]
    return {"commits": commits, "root_commit_at": _utc(min(times)) if times else None,
            "floor": commits[0]["at"] if commits else None, "tokenless_commits": found["tokenless"]}


def tokens_gate(collect_store):
    """The collector's `last_success_at`, or None without a readable status. The store's
    manifest cannot be the gate, because a read can touch it. This only reads a file."""
    def gate():
        try:
            status = json.loads((collect_store().root / "collector/status.json").read_text())
        except (OSError, ValueError):
            return None
        return status.get("last_success_at") if isinstance(status, dict) else None
    return gate


def _budget(rep, seconds, clock):
    """A timeout for `Store._dolt`: the seconds left of one cap across several calls."""
    end = clock() + seconds

    def left():
        rest = end - clock()
        if rest <= 0:
            raise rep.StoreTimeout("the usage read passed its cap", seconds)
        return rest
    return left


def reduce_tokens(rep, facts, meta, now):
    """The `tokens` snapshot's reductions of raw facts: known work only, and no device,
    host, source or segment identity. A Bead with runtime but no usage event is left out
    rather than shown as zero."""
    start, end = rep.WHOLE_HISTORY
    beads = rep.report(facts, meta, start, end, "bead", {}, now)["beads"]
    views = rep.usage_views(facts, start, end)
    return {"by_bead": {item["bead"]: item["work"] for item in beads
                        if item["events"] and item["bead"] and model.BEAD_ID.fullmatch(item["bead"])},
            "by_day": views["by_day"],
            "by_model": {model.scrub(name): work for name, work in views["by_model"].items()},
            "floors": views["floors"], "partial": views["partial"]}


def read_tokens(collect_store, usage_report_module, clock=time.monotonic):
    """The `tokens` snapshot. No store reads as `absent`, and nothing is created; a
    collection inside the store raises `Busy` before any Dolt call, so the last snapshot
    stays. Only the Dolt calls hold the lease: the reduction lets a waiting collector in."""
    store, rep = collect_store(), usage_report_module()
    if not (store.database / ".dolt").exists():
        raise cache.Absent()
    try:
        with store.read_lease():
            meta, facts = rep.load_facts(store, timeout=_budget(rep, TOKEN_READ_CAP, clock))
    except rep.LeaseAbsent:
        raise cache.Absent() from None
    except rep.LeaseBusy:
        raise cache.Busy() from None
    if meta is None:
        raise cache.Absent()
    snapshot = reduce_tokens(rep, facts, meta, dt.datetime.now(dt.timezone.utc))
    del facts
    spool = store.root / "collector/spool"
    snapshot["pending_batches"] = len(list(spool.glob("*.json"))) if spool.is_dir() else 0
    return snapshot
