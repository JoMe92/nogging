"""tmux primitives on Nogging's dedicated socket, preserving legacy argv."""
from __future__ import annotations

import shlex

from session_backend import Capabilities, KEYS


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

    def command(self, *args, check=True):
        return self._run(self.binary, "-L", self.socket, *args, check=check)

    @staticmethod
    def _name(ref):
        return ref["name"] if isinstance(ref, dict) else ref

    def start(self, name, cwd, env, argv, log):
        args = ["new-session", "-d", "-s", name, "-c", cwd]
        for key, value in env.items():
            args.extend(["-e", f"{key}={value}"])
        self._invoke(*args, "--", *argv)
        ref = {"name": name}
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

    def exists(self, ref):
        return self._invoke("has-session", "-t", self._name(ref), check=False).returncode == 0

    def kill(self, ref):
        self._invoke("kill-session", "-t", self._name(ref), check=False)

    def attach_argv(self, ref, read_only=False):
        return [self.binary, "-L", self.socket, "attach", "-t", self._name(ref)] + (
            ["-r"] if read_only else [])

    def agent_status(self, ref):
        return None

    def idle_shutdown(self):
        self._invoke("kill-server", check=False)

    def liveness_probe(self, ref):
        return {"backend": self.name, "argv": [self.binary, "-L", self.socket,
                "has-session", "-t", self._name(ref)]}
