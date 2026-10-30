"""One-pass scheduled-loop runner and bounded event log."""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile

import loop_schedule
import loop_state

UTC = timezone.utc
LOG_MAX = 1024 * 1024
LOG_GENERATIONS = 3
RETRY_MINUTES = (2, 4)
MAX_ATTEMPTS = 3
START_RECONCILE_MINUTES = 10
REASON_MAX = 300


def iso(value):
    return value.astimezone(UTC).isoformat().replace("+00:00", "Z")


def parse_time(value):
    return datetime.fromisoformat(str(value).replace("Z", "+00:00")).astimezone(UTC)


def event_path(root):
    return Path(root) / ".nogging/state/loops/runs.jsonl"


def append_event(root, event):
    """Append a prompt-free versioned event, rotating at the byte limit."""
    path = event_path(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    row = {"schema_version": 1, **event}
    encoded = (json.dumps(row, sort_keys=True, separators=(",", ":"),
                          default=lambda value: iso(value) if isinstance(value, datetime) else str(value)) + "\n").encode()
    with path.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if path.exists() and path.stat().st_size + len(encoded) > LOG_MAX:
            path.with_name(path.name + f".{LOG_GENERATIONS}").unlink(missing_ok=True)
            for index in range(LOG_GENERATIONS - 1, 0, -1):
                source = path.with_name(path.name + f".{index}")
                target = path.with_name(path.name + f".{index + 1}")
                if source.exists():
                    os.replace(source, target)
            os.replace(path, path.with_name(path.name + ".1"))
        with path.open("ab") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
    return row


def _write_state(root, state):
    loop_state.write_state(root, state)


def _base_event(name, run_id, slot, trigger, loop):
    if isinstance(run_id, datetime):
        run_id = f"{name}-{run_id.astimezone(UTC).strftime('%Y%m%dT%H%M%SZ')}"
    run = loop["run"]
    return {"at": None, "loop": name, "run_id": run_id,
            "slot": iso(slot), "trigger": trigger, "mode": run["mode"],
            "target": run.get("target"), "agent": run.get("agent"),
            "tier": run.get("tier")}


def _emit(root, now, base, name, event, **fields):
    append_event(root, {**base, "at": iso(now), "event": event,
                        **{key: value for key, value in fields.items() if value is not None}})


def _reason(exc):
    """One bounded line for the run log: an exception may carry a startup log."""
    lines = str(exc).splitlines()
    return (lines[0] if lines else type(exc).__name__)[:REASON_MAX]


def _active_for(loops):
    return sum(1 for value in loops.values()
               if value.get("active_run") and value["active_run"].get("mode") == "launch")


class LoopRunner:
    """Evaluate loops with host integrations supplied as small callbacks.

    `target` returns `(record, state)` for the canonical orchestrator, `usage`
    returns `(admitted, reason, observation)`, and `send` uses Nogging's
    verified delivery path. `sessions` carries the launch-mode operations:
    `model(run)`, `start(name, run, run_id, message)`, `state(session)`,
    `retire(run_id, reason)` and `adopt(run_id)`. They are injected so the
    scheduler is testable without starting a real session.
    """

    def __init__(self, root, definitions, *, target, usage, send, sessions=None,
                 now=lambda: datetime.now(UTC), host=None, multi_machine=False):
        self.root = Path(root).resolve()
        self.definitions = Path(definitions)
        self.target = target
        self.usage = usage
        self.send = send
        self.sessions = sessions
        self.now = now
        self.host = host or os.uname().nodename
        self.multi_machine = multi_machine
        self.lock_path = self.root / ".nogging/locks/loops.lock"

    @contextmanager
    def _lock(self):
        self.lock_path.parent.mkdir(parents=True, exist_ok=True)
        with self.lock_path.open("a") as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                yield False
                return
            yield True

    def tick(self):
        with self._lock() as acquired:
            if not acquired:
                print("loop tick: busy (another tick is running)")
                return 0
            return self._tick(self.now(), manual=False, only=None)

    def run_now(self, name):
        with self._lock() as acquired:
            if not acquired:
                print("loop run-now: busy (another tick is running)")
                return 0
            return self._tick(self.now(), manual=True, only=name)

    def _tick(self, instant, *, manual, only):
        import loop_config
        config = loop_config.load(self.definitions)
        if config is None:
            if only:
                raise ValueError(f"unknown loop {only!r}")
            if not manual:
                state = loop_state.read_state(self.root)
                state["last_tick"] = iso(instant)
                _write_state(self.root, state)
            return 0
        loop_config.validate_hosts(config, self.multi_machine)
        state = loop_state.read_state(self.root)
        state.setdefault("loops", {})
        if not manual:
            state["last_tick"] = iso(instant)
            _write_state(self.root, state)
            self._retire_removed(instant, config, state)
        selected = [only] if only else sorted(config["loops"])
        if only and only not in config["loops"]:
            raise ValueError(f"unknown loop {only!r}")
        for name in selected:
            loop = config["loops"][name]
            if loop.get("host") and loop["host"] != self.host:
                continue
            item = state["loops"].setdefault(name, {})
            self._advance_active(instant, name, loop, item)
            if item.get("active_run"):
                if manual:
                    active = item["active_run"]
                    base = _base_event(name, active["run_id"], parse_time(active["slot"]), "manual", loop)
                    self._skip(instant, name, loop, item, base, "previous-run-active")
                elif not item.get("deferred"):
                    config_now = loop_config.load(self.definitions)
                    approved, approval = loop_state.approval_status(
                        self.root, self.definitions, config_now, name)
                    anchor = item.get("last_evaluated") or (approval or {}).get("approved_at")
                    due = (loop_schedule.due({"timezone": config_now["timezone"], **loop["schedule"]},
                                             parse_time(anchor), instant) if approved and anchor else None)
                    if due is not None:
                        slot = due["slot"]
                        item["last_evaluated"] = iso(instant)
                        base = _base_event(name, f"{name}-{slot.strftime('%Y%m%dT%H%M%SZ')}",
                                           slot, "scheduled", loop)
                        deadline = loop_schedule.deadline(
                            {"timezone": config_now["timezone"], **loop["schedule"]}, slot)
                        self._defer_or_skip(instant, name, loop, item, base,
                                            "previous-run-active", deadline, False)
                continue
            if manual:
                slot = instant
            elif item.get("deferred"):
                pending = item["deferred"]
                slot = parse_time(pending["slot"])
                if instant >= parse_time(pending["deadline"]):
                    base = _base_event(name, pending["run_id"], slot, "scheduled", loop)
                    self._emit_outcome(instant, base, name, "skipped", pending["reason"])
                    item["last_outcome"] = "skipped"
                    item.pop("deferred", None)
                    continue
            elif item.get("retry"):
                run_id, retry = next(iter(item["retry"].items()))
                if instant < parse_time(retry["retry_at"]):
                    item["last_evaluated"] = iso(instant)
                    continue
                slot = parse_time(retry["slot"])
            else:
                approval_ok, approval = loop_state.approval_status(
                    self.root, self.definitions, config, name)
                anchor = item.get("last_evaluated") or (approval or {}).get("approved_at")
                if not anchor:
                    item["last_evaluated"] = iso(instant)
                    continue
                due = loop_schedule.due({"timezone": config["timezone"], **loop["schedule"]},
                                        parse_time(anchor), instant)
                if due is None:
                    item["last_evaluated"] = iso(instant)
                    continue
                slot = due["slot"]
                item["last_evaluated"] = iso(instant)
                if due["count"] > 1:
                    base = _base_event(name, slot, slot, "scheduled", loop)
                    _emit(self.root, instant, base, name, "missed", count=due["count"] - 1,
                          first=iso(due["missed_first"]), last=iso(due["missed_last"]))
            base = _base_event(name, slot, slot, "manual" if manual else "scheduled", loop)
            self._evaluate(instant, config, state, name, loop, item, slot, base,
                           manual=manual)
        _write_state(self.root, state)
        return 0

    def _retire_removed(self, instant, config, state):
        """Stop a launched run whose loop no longer exists; nothing else ends it."""
        for name in sorted(set(state["loops"]) - set(config["loops"])):
            item = state["loops"][name]
            active = item.get("active_run")
            if active and active.get("mode") == "launch":
                base = _base_event(name, active["run_id"], parse_time(active["slot"]),
                                   active["trigger"], {"run": {"mode": "launch"}})
                self._finish_launch(instant, name, item, base, active, "failed", "loop removed")
                if not item.get("active_run"):
                    del state["loops"][name]

    def _advance_active(self, instant, name, loop, item):
        active = item.get("active_run")
        if not active:
            return
        slot = parse_time(active["slot"])
        base = _base_event(name, active["run_id"], slot, active["trigger"], loop)
        started = parse_time(active["started_at"])
        launch = active.get("mode") == "launch"
        if active.get("event") == "starting":
            if instant - started >= timedelta(minutes=START_RECONCILE_MINUTES):
                self._reconcile_start(instant, name, item, base, active, launch)
            return
        if active.get("finishing"):
            self._finish_launch(instant, name, item, base, active, **active["finishing"])
            return
        import loop_config
        max_runtime = loop_config._runtime_minutes(loop["run"].get("max_runtime", "1h"), "max_runtime")
        if instant - started > timedelta(minutes=max_runtime):
            _emit(self.root, instant, base, name, "stale", reason="max-runtime",
                  session=active.get("session"))
            if launch:
                self._finish_launch(instant, name, item, base, active, "stopped-stale", "max-runtime")
                return
            _emit(self.root, instant, base, name, "unconfirmed", reason="max-runtime")
            item["active_run"] = None
            item["last_outcome"] = "unconfirmed"
            return
        if launch:
            self._advance_launch(instant, name, item, base, active)
            return
        record, state = self.target()
        if record is None or record.get("name") != active.get("session"):
            state = "target-not-running"
        if state == "idle":
            active["idle_ticks"] = active.get("idle_ticks", 0) + 1
            if active["idle_ticks"] >= 2:
                _emit(self.root, instant, base, name, "completed")
                item["active_run"] = None
                item["last_outcome"] = "completed"
                item["consecutive_failures"] = 0
        else:
            active["idle_ticks"] = 0
        # The state is persisted by the enclosing tick.

    def _reconcile_start(self, instant, name, item, base, active, launch):
        """Resolve a start that a crashed tick left behind, by its run ID."""
        session = None
        if launch:
            try:
                session = self.sessions.adopt(active["run_id"])
            except Exception as exc:
                # Nothing is known about the session yet: the next tick tries again.
                print(f"loop tick: cannot reconcile {active['run_id']}: {_reason(exc)}", file=sys.stderr)
                return
        if session:
            active.update(event="started", session=session)
            _emit(self.root, instant, base, name, "started", reason="adopted", session=session)
            item["last_outcome"] = "started"
            return
        _emit(self.root, instant, base, name, "failed", reason="start interrupted")
        self._failure(item, name, base, instant, "start interrupted")

    def _advance_launch(self, instant, name, item, base, active):
        state = self.sessions.state(active["session"])
        if state == "ended":
            self._finish_launch(instant, name, item, base, active, "failed", "session ended on its own")
        elif state == "idle":
            active["idle_ticks"] = active.get("idle_ticks", 0) + 1
            if active["idle_ticks"] >= 2:
                self._finish_launch(instant, name, item, base, active, "completed")
        else:
            active["idle_ticks"] = 0

    def _finish_launch(self, instant, name, item, base, active, event, reason=None):
        """Retire a run's session, then log its outcome. A retirement that fails
        leaves the run active with its outcome decided, so the next tick retries
        it, the session is never lost and doctor reports the stale run."""
        active["finishing"] = {"event": event, "reason": reason}
        try:
            log_path = self.sessions.retire(active["run_id"], f"loop run {event}")
        except Exception as exc:
            print(f"loop tick: cannot retire run {active['run_id']}: {_reason(exc)}", file=sys.stderr)
            return
        _emit(self.root, instant, base, name, event, reason=reason,
              session=active.get("session"), log_path=log_path)
        item["active_run"] = None
        if event == "completed":
            item["last_outcome"] = event
            item["consecutive_failures"] = 0
        else:
            self._failure(item, name, base, instant, reason, outcome=event)

    def _evaluate(self, instant, config, state, name, loop, item, slot, base, *, manual):
        approved, approval = loop_state.approval_status(self.root, self.definitions, config, name)
        deadline = instant + timedelta(seconds=1) if manual else loop_schedule.deadline(
            {"timezone": config["timezone"], **loop["schedule"]}, slot)
        reason = None
        if not loop["enabled"]: reason = "disabled"
        elif item.get("paused"): reason = "suspended" if item.get("suspended") else "paused"
        elif item.get("suspended"): reason = "suspended"
        elif not approved: reason = "unapproved"
        if reason:
            self._skip(instant, name, loop, item, base, reason)
            return
        if not manual and instant >= deadline:
            self._emit_outcome(instant, base, name, "missed", "deadline")
            item.get("retry", {}).pop(base["run_id"], None)
            item.pop("deferred", None)
            return
        if _active_for(state.get("loops", {})) >= config.get("scheduler", {}).get("max_active_launch_runs", 2) and loop["run"]["mode"] == "launch":
            self._defer_or_skip(instant, name, loop, item, base, "active-run-limit", deadline, manual)
            return
        run = loop["run"]
        launch = run["mode"] == "launch"
        record = None
        if not launch:
            record, target_state = self.target()
            if record is None or target_state == "ended":
                target_state = "target-not-running"
            if target_state != "idle":
                mapped = {"working": "target-busy", "needs_input": "target-needs-input",
                          "limit": "target-limit"}.get(target_state, target_state)
                self._defer_or_skip(instant, name, loop, item, base, mapped, deadline, manual)
                return
            agent, model = record.get("agent", "claude"), record.get("requested_model")
        else:
            agent = run["agent"]
            try:
                model = self.sessions.model(run)
            except Exception as exc:
                self._start_failed(instant, name, loop, item, base, deadline, 1,
                                   _reason(exc), False, manual)
                return
        admitted, denial, observation = self.usage(agent, model, loop.get("usage", {}))
        if not admitted:
            self._skip(instant, name, loop, item, base, denial, usage=observation)
            return
        usage_note = observation if observation.get("decision", "").startswith("unknown") else None
        run_id = f"{name}-{slot.strftime('%Y%m%dT%H%M%SZ')}"
        base = _base_event(name, run_id, slot, "manual" if manual else "scheduled", loop)
        retry = item.get("retry", {}).get(run_id, {})
        attempt = retry.get("attempt", 0) + 1
        start = {"run_id": run_id, "slot": iso(slot), "trigger": base["trigger"],
                 "started_at": iso(instant), "mode": run["mode"], "event": "starting",
                 "attempt": attempt, "idle_ticks": 0,
                 "session": record.get("name") if record else None}
        item["active_run"] = start
        _emit(self.root, instant, base, name, "starting", attempt=attempt,
              session=start["session"], usage=usage_note)
        _write_state(self.root, state)
        try:
            message = f"[nogg loop {name} run {run_id}]\n{self._prompt(name)}"
            if launch:
                start["session"] = self.sessions.start(name, run, run_id, message)
            else:
                self.send(record, message)
        except Exception as exc:
            denial = getattr(exc, "usage_denial", None)
            if denial:
                item["active_run"] = None
                self._skip(instant, name, loop, item, base, denial)
                return
            transient = getattr(exc, "transient", False)
            self._start_failed(instant, name, loop, item, base, deadline, attempt,
                               _reason(exc), transient, manual)
            return
        event = "started" if launch else "delivered"
        start["event"] = event
        start["usage"] = usage_note
        _emit(self.root, instant, base, name, event, attempt=attempt,
              session=start["session"], usage=usage_note)
        item.get("retry", {}).pop(run_id, None)
        item.pop("deferred", None)
        item["last_outcome"] = event
        if launch:
            _write_state(self.root, state)

    def _prompt(self, name):
        import loop_state
        return loop_state.prompt_path(self.root, self.definitions, name).read_text(encoding="utf-8")

    def _skip(self, instant, name, loop, item, base, reason, usage=None):
        self._emit_outcome(instant, base, name, "skipped", reason, usage=usage)
        item["last_outcome"] = "skipped"
        if item.get("deferred", {}).get("run_id") == base["run_id"]:
            item.pop("deferred", None)
        item.get("retry", {}).pop(base["run_id"], None)

    def _defer_or_skip(self, instant, name, loop, item, base, reason, deadline, manual):
        if manual or instant >= deadline:
            self._skip(instant, name, loop, item, base, reason)
            return
        pending = item.get("deferred")
        if not pending or pending.get("reason") != reason:
            self._emit_outcome(instant, base, name, "deferred", reason)
        item["deferred"] = {"run_id": base["run_id"], "slot": base["slot"],
                            "reason": reason, "deadline": iso(deadline)}

    def _start_failed(self, instant, name, loop, item, base, deadline, attempt, reason, transient, manual):
        item["active_run"] = None
        if transient and not manual and attempt < MAX_ATTEMPTS:
            delay = RETRY_MINUTES[attempt - 1]
            retry_at = instant + timedelta(minutes=delay)
            if retry_at < deadline:
                item.setdefault("retry", {})[base["run_id"]] = {
                    "attempt": attempt, "retry_at": iso(retry_at), "reason": reason,
                    "slot": base["slot"], "deadline": iso(deadline)}
                self._emit_outcome(instant, base, name, "retry-scheduled", reason,
                                   attempt=attempt, retry_at=iso(retry_at))
                return
        self._emit_outcome(instant, base, name, "failed", reason, attempt=attempt)
        item.get("retry", {}).pop(base["run_id"], None)
        self._failure(item, name, base, instant, reason)

    def _failure(self, item, name, base, instant, reason, outcome="failed"):
        item["active_run"] = None
        count = item.get("consecutive_failures", 0) + 1
        item["consecutive_failures"] = count
        item["last_outcome"] = outcome
        try:
            import loop_config
            config = loop_config.load(self.definitions)
            threshold = (config or {}).get("scheduler", {}).get("suspend_after_failures", 3)
        except ValueError:
            threshold = 3
        if count >= threshold:
            item["suspended"] = True
            item["suspend_reason"] = "consecutive-failures"
            item["last_outcome"] = "suspended"
            _emit(self.root, instant, base, name, "suspended", reason="consecutive-failures")

    def _emit_outcome(self, instant, base, name, event, reason=None, **fields):
        _emit(self.root, instant, base, name, event, reason=reason, **fields)
