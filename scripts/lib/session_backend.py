"""Session substrate primitives; supervision policy belongs to scripts/nogg."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

KEYS = frozenset({"enter", "escape", "ctrl+c", "ctrl+u", "backspace"})


class BackendError(RuntimeError):
    """A substrate operation failed without exposing its private request."""


@dataclass(frozen=True)
class Capabilities:
    capture_attributes: bool = False
    read_only_attach: bool = False
    agent_status: bool = False


@dataclass(frozen=True)
class LogCapture:
    path: str
    writer: str
    max_bytes: int = 1048576
    rotation_depth: int = 3


class SessionBackend(Protocol):
    """Report substrate facts; never change a session record or lifecycle state.

    References are JSON-serializable backend-owned values. Liveness returns
    (alive names, unknown names); callers must not infer death from unknown.
    """
    name: str
    capabilities: Capabilities

    def start(self, name, cwd, env, argv, log): ...
    def pid(self, ref): ...
    def send_text(self, ref, text): ...
    def send_keys(self, ref, key, *, check=True): ...
    def capture(self, ref, attributes=False): ...
    def live(self, records): ...
    def exists(self, ref): ...
    def kill(self, ref): ...
    def attach_argv(self, ref, read_only=False): ...
    def agent_status(self, ref): ...
    def idle_shutdown(self): ...
    def wire_log(self, ref, log, *, check=True): ...
    def liveness_probe(self, ref): ...


_REGISTRY = {}


def register(name, factory):
    """Register a backend factory without starting or querying its substrate."""
    _REGISTRY[name] = factory


def resolve(name, config, run, **kwargs) -> SessionBackend:
    """Build a backend using the CLI's configured command runner."""
    if name not in _REGISTRY:
        raise RuntimeError(f"session backend {name!r} is unavailable")
    return _REGISTRY[name](config, run, **kwargs)


def _tmux(config, run, **kwargs):
    from session_backend_tmux import TmuxBackend
    return TmuxBackend(config, run, **kwargs)


register("tmux", _tmux)


def _herdr(config, run, **kwargs):
    from session_backend_herdr import HerdrBackend
    return HerdrBackend(config, run, **kwargs)


register("herdr", _herdr)
