"""One-pass scheduled-loop runner and bounded event log."""
from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import tempfile

import loop_schedule
import loop_state

UTC = timezone.utc
LOG_MAX = 1024 * 1024
LOG_GENERATIONS = 3
RETRY_MINUTES = (2, 4)
MAX_ATTEMPTS = 3


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


def _active_for(loops):
    return sum(1 for value in loops.values()
               if value.get("active_run") and value["active_run"].get("mode") == "launch")


class LoopRunner:
    """Evaluate loops with host integrations supplied as small callbacks.

    `target` returns `(record, state)` for the canonical orchestrator, `usage`
    returns `(admitted, reason, observation)`, and `send` uses Nogging's
    verified delivery path. They are injected so the scheduler is testable
    without starting a real session.
    """

    def __init__(self, root, definitions, *, target, usage, send,
                 now=lambda: datetime.now(UTC), host=None, multi_machine=False):
        self.root = Path(root).resolve()
        self.definitions = Path(definitions)
        self.target = target
        self.usage = usage
        self.send = send
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
        state["last_tick"] = iso(instant)
        state.setdefault("loops", {})
        if not manual:
            _write_state(self.root, state)
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

    def _advance_active(self, instant, name, loop, item):
        active = item.get("active_run")
        if not active:
            return
        slot = parse_time(active["slot"])
        base = _base_event(name, active["run_id"], slot, active["trigger"], loop)
        started = parse_time(active["started_at"])
        import loop_config
        max_runtime = loop_config._runtime_minutes(loop["run"].get("max_runtime", "1h"), "max_runtime")
        if instant - started > timedelta(minutes=max_runtime):
            event = "unconfirmed"
            _emit(self.root, instant, base, name, event, reason="max-runtime")
            item["active_run"] = None
            item["last_outcome"] = event
            return
        if active.get("event") == "starting":
            if instant - started >= timedelta(minutes=10):
                _emit(self.root, instant, base, name, "failed", reason="start interrupted")
                self._failure(item, name, base, instant, "start interrupted")
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
        record, target_state = self.target()
        run = loop["run"]
        if run["mode"] == "send":
            if record is None or target_state == "ended":
                target_state = "target-not-running"
            if target_state != "idle":
                mapped = {"working": "target-busy", "needs_input": "target-needs-input",
                          "limit": "target-limit"}.get(target_state, target_state)
                self._defer_or_skip(instant, name, loop, item, base, mapped, deadline, manual)
                return
            agent, model = record.get("agent", "claude"), record.get("requested_model")
        else:
            self._skip(instant, name, loop, item, base, "launch-mode-not-installed")
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
            self.send(record, f"[nogg loop {name} run {run_id}]\n{self._prompt(name)}")
        except Exception as exc:
            transient = getattr(exc, "transient", False)
            self._start_failed(instant, name, loop, item, base, deadline, attempt,
                               str(exc), transient, manual)
            return
        start["event"] = "delivered"
        start["usage"] = usage_note
        _emit(self.root, instant, base, name, "delivered", attempt=attempt,
              session=start["session"], usage=usage_note)
        item.get("retry", {}).pop(run_id, None)
        item.pop("deferred", None)
        item["last_outcome"] = "delivered"

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

    def _failure(self, item, name, base, instant, reason):
        item["active_run"] = None
        count = item.get("consecutive_failures", 0) + 1
        item["consecutive_failures"] = count
        item["last_outcome"] = "failed"
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
