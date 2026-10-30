"""The optional user-level Codex Stop hook (session-wake design Decision 3).

Trust belongs to the operator: Codex runs a local hook outside its sandbox, so
only the one constant command below is ever trusted, and only as Codex itself
lists it from the user-level file. Everything here goes through Codex's own
app-server, so `hooks/list` is the single source of a hook's state. Probed on
Codex 0.164: a hook's key is `<hooks.json>:stop:<group>:<handler>`, so its trust
depends on its position in the file.
"""
from __future__ import annotations

import fcntl
import json
import os
import select
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Callable

HOOK_COMMAND = ('[ -z "${NOGG_SESSION_NAME:-}" ] || exec "$NOGG_SESSION_ROOT/scripts/nogg" '
                'session emit turn_end --guard --runtime codex')
HOOK_TIMEOUT_SECONDS = 30
# Also recognizes an edited copy, which status must report as `modified`.
HOOK_MARK = "session emit turn_end --guard"
REQUEST_TIMEOUT_SECONDS = 15.0
RESPONSE_LIMIT = 4 * 1024 * 1024
STATES = ("trusted", "untrusted", "modified", "missing", "unknown")


def _is_ours(handler: Any) -> bool:
    return isinstance(handler, dict) and HOOK_MARK in str(handler.get("command", ""))


def _stop_groups(document: Any) -> list[Any]:
    """The `Stop` array, refusing any shape this module does not understand."""
    if not isinstance(document, dict):
        raise ValueError("hooks.json must hold an object")
    hooks = document.get("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("hooks.json `hooks` must be an object")
    groups = hooks.get("Stop", [])
    if not isinstance(groups, list) or any(not isinstance(group, dict) for group in groups):
        raise ValueError("hooks.json `hooks.Stop` must be an array of objects")
    for group in groups:
        if not isinstance(group.get("hooks", []), list):
            raise ValueError("hooks.json Stop entry `hooks` must be an array")
    return groups


def has_hook(document: Any) -> bool:
    return any(_is_ours(handler) for group in _stop_groups(document) for handler in group.get("hooks", []))


def merge_stop(document: Any) -> bool:
    """Add the constant entry, or restore an edited copy where it stands. Appending
    never moves another entry, so no other hook's trust key changes. True if changed."""
    groups = _stop_groups(document)
    wanted = {"type": "command", "command": HOOK_COMMAND, "timeout": HOOK_TIMEOUT_SECONDS}
    for group in groups:
        for index, handler in enumerate(group.get("hooks", [])):
            if _is_ours(handler):
                if handler == wanted:
                    return False
                group["hooks"][index] = wanted
                return True
    document.setdefault("hooks", {}).setdefault("Stop", groups).append({"hooks": [wanted]})
    return True


def remove_stop(document: Any) -> bool:
    """Drop the entry and keep every other hook's trust key. An entry followed by
    another keeps its slot as an empty group, because splicing would renumber the
    later entry and silently untrust it. True if changed."""
    groups = _stop_groups(document)
    changed = False
    for group in groups:
        handlers = group.get("hooks", [])
        ours = [index for index, handler in enumerate(handlers) if _is_ours(handler)]
        if ours and ours[-1] != len(handlers) - len(ours):
            raise ValueError("another handler follows the Nogging hook in its group; remove it by hand")
        if ours:
            group["hooks"] = [handler for handler in handlers if not _is_ours(handler)]
            changed = True
    while groups and groups[-1] == {"hooks": []}:
        groups.pop()
    if changed and not groups:
        document["hooks"].pop("Stop", None)
    return changed


def read_document(path: Path) -> dict[str, Any]:
    """The parsed file, {} when absent. A symlink or malformed file is refused."""
    if path.is_symlink():
        raise ValueError("hooks.json is a symlink; refusing to replace it")
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except ValueError as exc:
        raise ValueError(f"hooks.json is not valid JSON: {exc}") from exc


def update_file(path: Path, change: Callable[[Any], bool]) -> bool:
    """Apply `change` under a lock and replace the file atomically, never widening
    its mode. The lock is held on the directory so no lock file is left behind."""
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    lock = os.open(path.parent, os.O_RDONLY)
    temporary = None
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        document = read_document(path)
        if not change(document):
            return False
        mode = (path.stat().st_mode & 0o777) if path.exists() else 0o600
        fd, temporary = tempfile.mkstemp(prefix=".nogging-hooks-", dir=path.parent)
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(json.dumps(document, indent=2, ensure_ascii=False) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
        return True
    finally:
        os.close(lock)
        if temporary is not None:
            Path(temporary).unlink(missing_ok=True)


class AppServer:
    """One bounded JSON-RPC conversation with `codex app-server` over stdio."""

    def __init__(self, argv: list[str], env: dict[str, str], cwd: str,
                 timeout: float = REQUEST_TIMEOUT_SECONDS) -> None:
        self.argv, self.env, self.cwd, self.timeout = argv, env, cwd, timeout
        self.process: subprocess.Popen | None = None
        self.next_id = 0
        self.buffer = b""

    def __enter__(self) -> "AppServer":
        self.process = subprocess.Popen(self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env=self.env, cwd=self.cwd)
        self.request("initialize", {"clientInfo": {"name": "nogg", "title": "Nogging", "version": "1"}})
        self._send({"method": "initialized"})
        return self

    def __exit__(self, *_exc: Any) -> None:
        process = self.process
        if process is None:
            return
        for stream in (process.stdin, process.stdout):
            try:
                stream.close()
            except OSError:
                pass
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

    def _send(self, message: dict[str, Any]) -> None:
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        self.process.stdin.flush()

    def _read_line(self, deadline: float) -> bytes:
        fd = self.process.stdout.fileno()
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([fd], [], [], remaining)[0]:
                raise TimeoutError("codex app-server did not answer in time")
            chunk = os.read(fd, 65536)
            if not chunk:
                raise ConnectionError("codex app-server exited")
            self.buffer += chunk
            if len(self.buffer) > RESPONSE_LIMIT:
                raise ValueError("codex app-server response too large")
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line

    def request(self, method: str, params: dict[str, Any]) -> Any:
        self.next_id += 1
        self._send({"id": self.next_id, "method": method, "params": params})
        deadline = time.monotonic() + self.timeout
        while True:
            message = json.loads(self._read_line(deadline))
            if isinstance(message, dict) and message.get("id") == self.next_id:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message.get("result")


def list_hooks(server: Any, cwd: str) -> list[dict[str, Any]]:
    result = server.request("hooks/list", {"cwds": [cwd]})
    hooks: list[dict[str, Any]] = []
    for row in (result or {}).get("data", []):
        hooks.extend(hook for hook in row.get("hooks", []) if isinstance(hook, dict))
    return hooks


def find_hook(hooks: list[dict[str, Any]], path: Path) -> dict[str, Any] | None:
    """The user-level Stop hook Codex lists from `path` that is ours, if any."""
    for hook in hooks:
        if (hook.get("eventName") == "stop" and hook.get("source") == "user"
                and HOOK_MARK in str(hook.get("command", ""))
                and Path(str(hook.get("sourcePath"))).resolve() == path.resolve()):
            return hook
    return None


def is_exact(hook: dict[str, Any]) -> bool:
    """Whether this listing is the constant hook, the only one ever trusted."""
    return (hook.get("command") == HOOK_COMMAND and hook.get("timeoutSec") == HOOK_TIMEOUT_SECONDS
            and hook.get("handlerType") == "command" and hook.get("async") in (False, None))


def hook_state(hook: dict[str, Any] | None) -> str:
    """`trusted`, `untrusted`, `modified`, or `unknown` for a listing nothing explains."""
    if hook is None:
        return "unknown"
    status = hook.get("trustStatus")
    if status == "trusted" and not is_exact(hook):
        return "modified"
    if status == "trusted" and hook.get("enabled") is False:
        return "untrusted"
    return status if status in ("trusted", "untrusted", "modified") else "unknown"


def _trust_key_path(hook: dict[str, Any]) -> str:
    return "hooks.state." + json.dumps(hook["key"])


def trust(server: Any, hook: dict[str, Any]) -> None:
    server.request("config/value/write", {"keyPath": _trust_key_path(hook), "mergeStrategy": "upsert",
                                          "value": {"trusted_hash": hook["currentHash"]}})


def untrust(server: Any, hook: dict[str, Any]) -> None:
    server.request("config/value/write", {"keyPath": _trust_key_path(hook), "mergeStrategy": "replace",
                                          "value": None})
