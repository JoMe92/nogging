"""tmux primitives on Nogging's dedicated socket, preserving legacy argv."""
from __future__ import annotations

import os
import socket
import shlex
import struct

from session_backend import BackendError, Capabilities, KEYS


def _namespace_links(pid):
    """Return PID and mount namespace links for a visible process."""
    return (os.readlink(f"/proc/{pid}/ns/pid"),
            os.readlink(f"/proc/{pid}/ns/mnt"))


def server_namespace(config):
    """Classify the process listening on Nogging's dedicated tmux socket.

    The PID comes from kernel peer credentials, never from tmux's namespace-
    local display-message output. Namespace reads are isolated for testing.
    """
    socket_name = config.get("session_tmux_socket", "nogging")
    socket_dir = os.environ.get("TMUX_TMPDIR", "/tmp")
    path = os.path.join(socket_dir, f"tmux-{os.getuid()}", socket_name)
    fenced = os.environ.get("NOGG_OPENSPEC_FENCED") == "1"
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            client.settimeout(0.5)
            client.connect(path)
            _, pid, _ = struct.unpack("3i", client.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
        finally:
            client.close()
    except (FileNotFoundError, ConnectionRefusedError):
        return {"class": "down", "pid": None}
    except OSError:
        return {"class": "unknown", "pid": None}
    if pid == 0:
        return {"class": "outside" if fenced else "unknown", "pid": 0}
    if fenced:
        return {"class": "sandboxed", "pid": pid}
    try:
        server_pid_ns, server_mnt_ns = _namespace_links(pid)
        caller_pid_ns, caller_mnt_ns = _namespace_links("self")
    except (OSError, ValueError):
        return {"class": "unknown", "pid": pid}
    same = server_pid_ns == caller_pid_ns and server_mnt_ns == caller_mnt_ns
    return {"class": "host" if same else "sandboxed", "pid": pid}


class TmuxBackend:
    name = "tmux"
    capabilities = Capabilities(capture_attributes=True, read_only_attach=True)
    _KEYS = {"enter": "Enter", "escape": "Escape", "ctrl+c": "C-c", "ctrl+u": "C-u"}

    def __init__(self, config, run, *, invoke=None):
        self.binary = config.get("session_tmux_command", "tmux")
        self.socket = config.get("session_tmux_socket", "nogging")
        self._run = run
        # Optional legacy transport hook keeps existing embedders/test doubles
        # working; all command construction still lives in this module.
        self._invoke = invoke or self.command
        self.config = config

    def server_namespace(self):
        return server_namespace(self.config)

    @staticmethod
    def _fenced_prefix():
        return ("-N",) if os.environ.get("NOGG_OPENSPEC_FENCED") == "1" else ()

    def command(self, *args, check=True):
        return self._run(self.binary, "-L", self.socket, *self._fenced_prefix(),
                         *args, check=check)

    def prepare(self, name, cwd):
        """Check fenced callers can use the host server before any record is written."""
        if os.environ.get("NOGG_OPENSPEC_FENCED") != "1":
            return {"name": name, "socket": self.socket}
        try:
            result = self.command("list-sessions", check=False)
        except OSError as exc:
            raise BackendError(
                f"tmux server -L {self.socket} is not running; a sandboxed session "
                "cannot start it, because it would end with this session; launch "
                f"from an unsandboxed shell (the operator or the Orchestration Agent): {exc}"
            ) from exc
        if getattr(result, "returncode", 1) != 0:
            stderr = (getattr(result, "stderr", "") or "").strip()
            reason = (f": {stderr}" if stderr and "no server running" not in stderr.lower()
                      else "")
            raise BackendError(
                f"tmux server -L {self.socket} is not running; a sandboxed session "
                "cannot start it, because it would end with this session; launch "
                f"from an unsandboxed shell (the operator or the Orchestration Agent){reason}"
            )
        return {"name": name, "socket": self.socket}

    @staticmethod
    def _name(ref):
        return ref["name"] if isinstance(ref, dict) else ref

    def start(self, name, cwd, env, argv, log):
        args = ["new-session", "-d", "-s", name, "-c", cwd]
        for key, value in env.items():
            args.extend(["-e", f"{key}={value}"])
        self._invoke(*args, "--", *argv)
        ref = {"name": name, "socket": self.socket}
        self.wire_log(ref, log)
        return ref

    def wire_log(self, ref, log, *, check=True):
        """Wire capture at start, or rewire an adopted orchestrator's log."""
        sink = "exec " + " ".join(shlex.quote(str(a)) for a in (
            log.writer, log.path, log.max_bytes, log.rotation_depth))
        self._invoke("pipe-pane", "-o", "-t", self._name(ref), sink, check=check)

    def pid(self, ref):
        result = self._invoke("display-message", "-p", "-t", self._name(ref),
                              "#{pane_pid}", check=False)
        raw = getattr(result, "stdout", "").strip()
        return int(raw) if raw.isdigit() and int(raw) > 0 else None

    def send_text(self, ref, text):
        self._invoke("send-keys", "-t", self._name(ref), "-l", text)

    def send_keys(self, ref, key, *, check=True):
        if key not in KEYS:
            raise ValueError(f"unsupported session key: {key!r}")
        self._invoke("send-keys", "-t", self._name(ref), self._KEYS[key], check=check)

    def capture(self, ref, attributes=False):
        args = ["capture-pane", "-p"] + (["-e"] if attributes else [])
        result = self._invoke(*args, "-t", self._name(ref), check=False)
        return result.stdout if result.returncode == 0 else ""

    def live(self, records):
        # Include unmanaged names: collision checks and idle shutdown have
        # always inspected the entire dedicated server. A failed query keeps
        # tmux's legacy empty-set behavior; it does not create unknown names.
        result = self._invoke("list-sessions", "-F", "#{session_name}", check=False)
        alive = ({line.strip() for line in result.stdout.splitlines() if line.strip()}
                 if result.returncode == 0 else set())
        return alive, set()

    def empty(self):
        """Return True only if list-sessions succeeded and listed no sessions.

        A failed listing counts as not empty so cleanup never kills a server
        whose state could not be determined.
        """
        try:
            result = self._invoke("list-sessions", "-F", "#{session_name}", check=False)
        except Exception:
            return False
        if getattr(result, "returncode", 1) != 0:
            return False
        stdout = getattr(result, "stdout", "") or ""
        return not any(line.strip() for line in stdout.splitlines())

    def exists(self, ref):
        return self._invoke("has-session", "-t", self._name(ref), check=False).returncode == 0

    def kill(self, ref):
        self._invoke("kill-session", "-t", self._name(ref), check=False)

    def attach_argv(self, ref, read_only=False):
        return ([self.binary, "-L", self.socket, *self._fenced_prefix(),
                 "attach", "-t", self._name(ref)] + (["-r"] if read_only else []))

    def agent_status(self, ref):
        return None

    def idle_shutdown(self):
        self._invoke("kill-server", check=False)

    def liveness_probe(self, ref):
        return {"backend": self.name, "argv": [self.binary, "-L", self.socket,
                *self._fenced_prefix(), "has-session", "-t", self._name(ref)]}
