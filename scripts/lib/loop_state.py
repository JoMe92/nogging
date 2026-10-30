"""Host-local, atomic state and approval helpers for scheduled loops."""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import tempfile
from datetime import datetime, timezone
import pwd

import loop_config

# Written by pause, resume and remove, which do not wait for a running tick.
OPERATOR_FIELDS = ("paused", "suspended", "suspend_reason", "consecutive_failures")


def _atomic_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True,
                      default=lambda item: item.isoformat().replace("+00:00", "Z")
                      if isinstance(item, datetime) else str(item))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass
        raise


def read_json(path: Path, default):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default
    except (OSError, ValueError) as exc:
        raise ValueError(f"cannot read host loop state {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"malformed host loop state {path}: expected an object")
    return value


def state_path(main_checkout) -> Path:
    return _safe_path(main_checkout, ".nogging/state/loops/state.json")


def approvals_path(main_checkout) -> Path:
    return _safe_path(main_checkout, ".nogging/state/loops/approvals.json")


def _safe_path(main_checkout, relative):
    root = Path(main_checkout).resolve()
    path = root / relative
    if not path.resolve().is_relative_to(root):
        raise ValueError(f"loop state path must remain under the main checkout: {path}")
    return path


def prompt_path(main_checkout, definitions_path, name):
    path = loop_config.prompt_path(definitions_path, name)
    if not path.resolve().is_relative_to(Path(main_checkout).resolve()):
        raise ValueError(f"loop prompt path must remain under the main checkout: {path}")
    return path


def read_state(main_checkout):
    return read_json(state_path(main_checkout), {"schema_version": 1, "loops": {}})


def write_state(main_checkout, value):
    _atomic_json(state_path(main_checkout), value)


@contextmanager
def state_lock(main_checkout):
    """Serialize one read-modify-write of state.json. Held briefly, never across
    a launch, so an operator command does not wait for a tick."""
    path = state_path(main_checkout).with_suffix(".lock")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def operator_fields(state):
    return {name: {field: item.get(field) for field in OPERATOR_FIELDS}
            for name, item in state.get("loops", {}).items()}


def save_tick_state(main_checkout, state, seen):
    """Write a tick's state over what the operator changed since `seen`.

    A tick holds its copy across launches, so writing it back whole would undo
    a pause, resume or remove made meanwhile. Returns the new `seen`."""
    with state_lock(main_checkout):
        disk = read_state(main_checkout).get("loops", {})
        loops = state.setdefault("loops", {})
        for name in set(disk) | set(seen):
            current = disk.get(name)
            if current is None:
                if name in seen and not loops.get(name, {}).get("active_run"):
                    loops.pop(name, None)
                continue
            before = seen.get(name, {})
            for field in OPERATOR_FIELDS:
                if current.get(field) == before.get(field):
                    continue
                if field in current:
                    loops.setdefault(name, {})[field] = current[field]
                else:
                    loops.setdefault(name, {}).pop(field, None)
        write_state(main_checkout, state)
    return operator_fields(state)


def _prompt_bytes(main_checkout, definitions_path, name):
    prompt = prompt_path(main_checkout, definitions_path, name)
    loop_config.check_prompt(prompt)
    return prompt.read_bytes()


def current_hash(main_checkout, definitions_path, config, name):
    return loop_config.approval_hash(config["timezone"], config["loops"][name],
                                     _prompt_bytes(main_checkout, definitions_path, name))


def approval_status(main_checkout, definitions_path, config, name):
    entry = read_json(approvals_path(main_checkout), {"schema_version": 1, "loops": {}})
    record = entry.get("loops", {}).get(name)
    if not isinstance(record, dict):
        return False, None
    try:
        expected = current_hash(main_checkout, definitions_path, config, name)
    except (OSError, ValueError):
        return False, record
    return record.get("sha256") == expected, record


def approve(main_checkout, definitions_path, config, name, *, at=None, user=None):
    digest = current_hash(main_checkout, definitions_path, config, name)
    path = approvals_path(main_checkout)
    ledger = read_json(path, {"schema_version": 1, "loops": {}})
    loops = ledger.setdefault("loops", {})
    loops[name] = {"sha256": digest,
                   "approved_at": at or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                   "user": user or _os_username()}
    ledger["schema_version"] = 1
    _atomic_json(path, ledger)
    return digest


def _os_username():
    name = pwd.getpwuid(os.getuid()).pw_name
    return str(os.getuid()) if "@" in name else name


def remove_approval(main_checkout, name):
    path = approvals_path(main_checkout)
    ledger = read_json(path, {"schema_version": 1, "loops": {}})
    if ledger.get("loops", {}).pop(name, None) is not None:
        _atomic_json(path, ledger)
