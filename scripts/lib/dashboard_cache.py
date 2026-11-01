"""Source cells and the one background refresher of `nogg dashboard`, with an injected
clock.

One daemon thread runs the sources strictly in turn (`Refresher.step`). A request
thread only reads a published, immutable snapshot (`status`, `snapshot`, `render`) and
records demand (`touch`), so a request never starts a subprocess and ten phones cannot
pile up `bd` calls. Nothing is written to disk: a disk cache would copy notes out of
their present protection.

A cell moves between `loading`, `fresh`, `refreshing`, `stale`, `unavailable` and
`absent`. A failed source keeps its last good snapshot and backs off from 30 s to 10 min
without touching another source. The clock is injected: `step` is a plain call, so a test
drives the intervals, the backoff and the idle rule without a sleep.
"""
from __future__ import annotations

import hashlib, json, threading, time
from collections import OrderedDict
from dataclasses import dataclass, replace
from datetime import datetime, timezone

# Fill order after start, and the interval of each source in seconds (design Decision 6).
ORDER = ("beads", "sessions", "tests", "git", "tokens")
INTERVALS = {"beads": 30.0, "sessions": 30.0, "tests": 120.0, "git": 600.0, "tokens": 900.0}
BACKOFF_FIRST, BACKOFF_MAX = 30.0, 600.0
IDLE_AFTER = 300.0
BUSY_RETRY = 30.0
STALE_AFTER = 2.0          # a snapshot older than this many intervals reads `stale`
RENDER_ENTRIES = 32
REASONS = ("dolt_unreachable", "bd_absent", "bd_error", "busy", "error")
STATES = ("loading", "fresh", "refreshing", "stale", "unavailable", "absent")


class SourceError(Exception):
    """A source could not be read. `kind` is a fixed class; the text is never kept."""

    def __init__(self, kind="error"):
        super().__init__(kind)
        self.kind = kind if kind in REASONS else "error"


class Absent(Exception):
    """The source does not exist in this repository: it reads "not available here"."""


class Busy(Exception):
    """The source cannot be read right now and keeps its snapshot, for example while the
    collector holds its lock. It is retried on a later tick and is no failure."""


@dataclass(frozen=True)
class Published:
    """Everything a reader of a cell sees, swapped as one unit."""
    state: str
    snapshot: object
    as_of: float | None         # wall-clock time of the last good load
    checked: float | None       # clock time of the last good check, a skipped reload included
    generation: int
    reason: str | None
    digest: str | None


class Cell:
    def __init__(self, name, reader, interval, gate=None):
        self.name, self.reader, self.interval, self.gate = name, reader, interval, gate
        self.published = Published("loading", None, None, None, 0, None, None)
        self.due, self.failures, self.gate_token = 0.0, 0, None


def digest_of(snapshot):
    return hashlib.sha256(json.dumps(snapshot, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class Refresher:
    def __init__(self, readers=None, gates=None, *, clock=time.monotonic, wall_clock=time.time,
                 intervals=None):
        readers, gates = readers or {}, gates or {}
        unknown = [name for name in readers if name not in ORDER]
        if unknown:
            raise ValueError(f"unknown dashboard source: {unknown[0]}")
        intervals = {**INTERVALS, **(intervals or {})}
        self.cells = {name: Cell(name, readers[name], intervals[name], gates.get(name))
                      for name in ORDER if name in readers}
        self.clock, self.wall_clock = clock, wall_clock
        self.last_demand = clock()
        self._renders, self._render_lock = OrderedDict(), threading.Lock()
        self._changed = threading.Condition()
        self._wake, self._stop, self._thread = threading.Event(), threading.Event(), None

    # --- what request threads use -------------------------------------------------

    def touch(self):
        """Record demand. A request after an idle stretch wakes the refresher."""
        self.last_demand = self.clock()
        self._wake.set()

    def status(self):
        """{source: {state, as_of, generation[, reason]}} as the envelope states it."""
        now, out = self.clock(), {}
        for name, cell in self.cells.items():
            pub = cell.published
            state = pub.state
            if state == "fresh" and now - pub.checked > STALE_AFTER * cell.interval:
                state = "stale"      # the refresher was idle or is busy on a slow source
            item = {"state": state, "as_of": iso(pub.as_of), "generation": pub.generation}
            if pub.reason and state in ("stale", "unavailable"):
                item["reason"] = pub.reason
            out[name] = item
        return out

    def snapshot(self, name):
        """The last good snapshot of a source, or None while it is loading, unavailable or absent."""
        cell = self.cells.get(name)
        return cell.published.snapshot if cell else None

    def render(self, route, names, build):
        """`build(snapshots)` for the named sources, memoised on their states, times and
        generations, so a response is built and compressed once per change and not once per
        request. The memo is an LRU of 32 entries."""
        names = [name for name in names if name in self.cells]
        status = self.status()
        key = (route, tuple((name, tuple(sorted(status[name].items()))) for name in names))
        with self._render_lock:
            if key in self._renders:
                self._renders.move_to_end(key)
                return self._renders[key]
        snapshots = {name: self.cells[name].published.snapshot for name in names}
        value = build(snapshots, {name: status[name] for name in names})
        with self._render_lock:
            self._renders[key] = value
            while len(self._renders) > RENDER_ENTRIES:
                self._renders.popitem(last=False)
        return value

    # --- the refresher ------------------------------------------------------------

    def idle(self):
        return self.clock() - self.last_demand > IDLE_AFTER

    def step(self):
        """Run the first due source, and return its name; None when idle or nothing is due."""
        if self.idle():
            return None
        now = self.clock()
        for cell in self.cells.values():
            if cell.due <= now:
                self._refresh(cell)
                return cell.name
        return None

    def wait_time(self):
        """Seconds until the next source is due, or None when idle (wait for a request)."""
        if self.idle() or not self.cells:
            return None
        return max(0.0, min(cell.due for cell in self.cells.values()) - self.clock())

    def _publish(self, cell, **changes):
        cell.published = replace(cell.published, **changes)
        with self._changed:
            self._changed.notify_all()

    def _refresh(self, cell):
        old = cell.published
        # The gate runs first: no change, no reload, and the snapshot stays as it is.
        token = cell.gate() if cell.gate else None
        if cell.gate and old.snapshot is not None and token == cell.gate_token and old.state in ("fresh", "stale"):
            self._publish(cell, state="fresh", checked=self.clock(), reason=None)
            cell.due, cell.failures = self.clock() + cell.interval, 0
            return
        self._publish(cell, state="refreshing" if old.snapshot is not None else "loading")
        try:
            snapshot = cell.reader()
        except Absent:
            self._publish(cell, state="absent", snapshot=None, as_of=None, checked=self.clock(), reason=None,
                          digest=None)
            cell.gate_token, cell.failures, cell.due = token, 0, self.clock() + cell.interval
            return
        except Busy:
            self._publish(cell, state="stale" if old.snapshot is not None else "loading", reason="busy")
            cell.due = self.clock() + BUSY_RETRY
            return
        except Exception as exc:
            # Only a fixed class leaves this method; the exception text never does.
            kind = exc.kind if isinstance(exc, SourceError) else "error"
            cell.failures += 1
            cell.due = self.clock() + min(BACKOFF_MAX, BACKOFF_FIRST * 2 ** (cell.failures - 1))
            self._publish(cell, state="stale" if old.snapshot is not None else "unavailable", reason=kind)
            return
        digest = digest_of(snapshot)
        changed = digest != old.digest
        cell.gate_token, cell.failures, cell.due = token, 0, self.clock() + cell.interval
        self._publish(cell, state="fresh", snapshot=snapshot if changed else old.snapshot,
                      as_of=self.wall_clock(), checked=self.clock(), reason=None, digest=digest,
                      generation=old.generation + 1 if changed else old.generation)

    def wait_until(self, predicate, timeout=10.0):
        """Block until `predicate(status)` holds or `timeout` passes; for tests and callers
        that must not poll with sleeps."""
        with self._changed:
            return self._changed.wait_for(lambda: predicate(self.status()), timeout)

    def start(self):
        if self._thread is None:
            self._thread = threading.Thread(target=self._run, name="dashboard-refresher", daemon=True)
            self._thread.start()

    def _run(self):
        while not self._stop.is_set():
            if self.step() is not None:
                continue
            wait = self.wait_time()
            self._wake.wait(wait)
            self._wake.clear()

    def stop(self, timeout=5.0):
        self._stop.set()
        self._wake.set()
        if self._thread is not None:
            self._thread.join(timeout)


def iso(timestamp):
    if timestamp is None:
        return None
    return datetime.fromtimestamp(timestamp, timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
