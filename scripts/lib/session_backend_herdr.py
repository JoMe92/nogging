"""Local herdr CLI primitives, with layout.apply as the sole socket operation."""
from __future__ import annotations

import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import subprocess
import sys
import time
import uuid

from session_backend import BackendError, Capabilities, KEYS


def process_start(pid):
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        return None if fields[0] == "Z" else fields[19]
    except (OSError, IndexError):
        return None


def pid_namespace():
    try:
        return os.readlink("/proc/self/ns/pid")
    except OSError:
        return None


def same_namespace(namespace):
    # Old records can only be interpreted locally by an unfenced host caller.
    if namespace is None:
        return os.environ.get("NOGG_OPENSPEC_FENCED") != "1"
    return bool(namespace and namespace == pid_namespace())


class HerdrBackend:
    name = "herdr"
    # All three gated runtimes passed recorder, status and ANSI capture on 0.9.5.
    capabilities = Capabilities(capture_attributes=True, agent_status=True)
    _RECORDER_AGENTS = frozenset({"claude", "codex", "antigravity"})
    _CONFIG = ("[session]\nresume_agents_on_restore = false\n"
               "[update]\nversion_check = false\nmanifest_check = false\n"
               "[experimental]\npane_history = false\n")

    def __init__(self, config, run):
        self.binary = config.get("session_herdr_command", "herdr")
        self.session = config.get("session_herdr_session", "nogging")
        if not isinstance(self.session, str) or not re.fullmatch(r"[a-zA-Z0-9_-]+", self.session):
            raise BackendError("herdr backend requires a simple dedicated session name")
        self.root = Path(config.get("session_repository_root", Path(__file__).resolve().parents[2]))
        self.slug = config.get("session_repository_slug", self.root.name)
        self.state = Path(config.get("session_herdr_state_dir", self.root / ".nogging/state/herdr")) / self.session
        self.recorder = self.root / "scripts/session-pty-recorder"
        self.record_dir = self.root / config.get("session_state_dir", ".nogging/state/sessions")
        self.timeout = 5.0
        self._run = run
        self._prepared = None

    def _cli(self, *args, ref=None, check=True):
        namespace = ref.get("herdr_session", self.session) if isinstance(ref, dict) else self.session
        try:
            result = self._run(self.binary, "--session", namespace, *args,
                               check=False, timeout=self.timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise BackendError("herdr backend CLI unavailable or timed out") from exc
        if check and result.returncode:
            code = self._error_code(result)
            raise BackendError(f"herdr backend CLI failed ({code})")
        return result

    @staticmethod
    def _error_code(result):
        try:
            return json.loads(result.stderr or result.stdout)["error"]["code"]
        except (ValueError, KeyError, TypeError):
            return f"exit {result.returncode}"

    def _json(self, *args, ref=None):
        result = self._cli(*args, ref=ref)
        try:
            value = json.loads(result.stdout)
            if not isinstance(value, dict):
                raise ValueError()
            value = value.get("result", value)
            if not isinstance(value, dict):
                raise ValueError()
            return value
        except (ValueError, TypeError) as exc:
            raise BackendError("herdr backend returned malformed CLI JSON") from exc

    def preflight(self, agent):
        """Only read-only checks; refuse ungated agents before any side effect."""
        if agent not in self._RECORDER_AGENTS:
            raise BackendError(f"herdr recorder gate has not passed for {agent}; use --backend tmux")
        if not isinstance(self.binary, str) or not shutil.which(self.binary):
            raise BackendError("herdr backend binary is missing; install herdr or use --backend tmux")
        try:
            result = subprocess.run([str(self.recorder), "--contract"], capture_output=True,
                                    text=True, timeout=self.timeout)
            contract = json.loads(result.stdout)
            if (result.returncode or contract.get("version") != 1
                    or contract.get("positional") != 3
                    or "pty-recorder" not in contract.get("features", [])):
                raise ValueError()
        except (OSError, ValueError, AttributeError, subprocess.TimeoutExpired) as exc:
            raise BackendError("herdr recorder contract incompatible; run Nogging update") from exc

    @staticmethod
    def _server_env(config_path):
        # Allow only host identity, executable/config search and terminal locale.
        keys = {"HOME", "PATH", "USER", "LOGNAME", "SHELL", "TERM", "LANG",
                "LC_ALL", "LC_CTYPE", "LC_NUMERIC", "LC_TIME", "LC_COLLATE", "LC_MONETARY",
                "LC_MESSAGES", "LC_PAPER", "LC_NAME", "LC_ADDRESS", "LC_TELEPHONE",
                "LC_MEASUREMENT", "LC_IDENTIFICATION", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
                "XDG_STATE_HOME", "XDG_RUNTIME_DIR"}
        env = {k: v for k, v in os.environ.items() if k in keys}
        env["HERDR_CONFIG_PATH"] = str(config_path)
        return env

    def _running(self):
        result = self._cli("status")
        match = re.search(r"^server:\s*\n\s+status:\s*(running|not running)\s*$",
                          result.stdout, re.M)
        if not match:
            raise BackendError("herdr backend returned unrecognized server status")
        return match[1] == "running"

    def _reported_socket(self):
        value = self._json("session", "list", "--json")
        sessions = [s for s in value.get("sessions", []) if s.get("name") == self.session]
        if len(sessions) != 1 or not isinstance(sessions[0].get("socket_path"), str):
            raise BackendError("herdr backend could not resolve dedicated session socket")
        path = sessions[0]["socket_path"]
        self._check_path_length(path)
        return path

    @staticmethod
    def _check_path_length(path):
        if not os.path.isabs(path) or len(os.fsencode(path)) >= 108:
            raise BackendError("herdr socket path must be absolute and shorter than 108 bytes")

    @classmethod
    def verify_socket(cls, path):
        cls._check_path_length(path)
        try:
            info = os.lstat(path)
        except OSError as exc:
            raise BackendError("herdr socket path is unavailable") from exc
        if stat.S_ISLNK(info.st_mode):
            raise BackendError("herdr socket must not be a symlink")
        if not stat.S_ISSOCK(info.st_mode):
            raise BackendError("herdr socket path is not a Unix socket")
        if info.st_uid != os.getuid():
            raise BackendError("herdr socket must be owned by the invoking user")
        if stat.S_IMODE(info.st_mode) != 0o600:
            raise BackendError("herdr socket mode must be 0600")
        return {"dev": info.st_dev, "ino": info.st_ino, "ctime_ns": info.st_ctime_ns}

    _HOST_START = ("start it from an unsandboxed shell with "
                   "scripts/nogg session herdr-server start, or launch from that shell")

    def _owned_server(self):
        """Verify the receipt without interpreting a foreign namespace's PID."""
        try:
            owned = json.loads((self.state / "server.json").read_text())
            if (type(owned["pid"]) is not int or owned["pid"] <= 0 or not owned["start"]
                    or (self.state / "config.toml").read_bytes() != self._CONFIG.encode()):
                raise ValueError("receipt or config mismatch")
            identity = self.verify_socket(self._reported_socket())
            namespace = owned.get("pid_ns")
            legacy = namespace is None or "socket" not in owned
            if legacy:
                if (os.environ.get("NOGG_OPENSPEC_FENCED") == "1"
                        or not same_namespace(namespace)):
                    raise ValueError("legacy receipt is unverifiable when fenced; " + self._HOST_START)
            elif (not isinstance(namespace, str) or not namespace
                  or owned["socket"] != identity):
                raise ValueError("socket identity or PID namespace mismatch")
            if (legacy or same_namespace(namespace)) and process_start(owned["pid"]) != owned["start"]:
                raise ValueError("server process identity mismatch")
            if legacy:
                # A host-side verification is sufficient to make an old
                # receipt usable from fenced callers in this checkout.
                host_namespace = pid_namespace()
                if not host_namespace:
                    raise ValueError("host PID namespace identity is unavailable")
                owned.update(pid_ns=host_namespace, socket=identity)
                receipt_path = self.state / "server.json"
                receipt_path.write_text(json.dumps(owned))
                receipt_path.chmod(0o600)
            return owned
        except (OSError, ValueError, KeyError, TypeError, BackendError) as exc:
            raise BackendError(f"herdr dedicated server is not owned by Nogging: {exc}; "
                               "choose an unused session_herdr_session") from exc

    def _ensure_server(self):
        # A fenced caller must only inspect existing host state. Even mkdir or
        # taking a new launch lock would be an unwanted side effect on refusal.
        if os.environ.get("NOGG_OPENSPEC_FENCED") == "1":
            if not self._running():
                raise BackendError("herdr server is down; " + self._HOST_START)
            return self._owned_server()
        self.state.mkdir(parents=True, exist_ok=True, mode=0o700)
        config_path = self.state / "config.toml"
        receipt = self.state / "server.json"
        with (self.state / "launch.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if self._running():
                # A pre-existing server must be ours, with our immutable config.
                return self._owned_server()
            else:
                # Discover even a stopped session's reported path before spawn.
                sessions = self._json("session", "list", "--json").get("sessions", [])
                prior = next((s for s in sessions if s.get("name") == self.session), None)
                path = (prior.get("socket_path") if prior else
                        str(Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config")))
                            / "herdr/sessions" / self.session / "herdr.sock"))
                self._check_path_length(path)
                config_path.write_text(self._CONFIG)
                config_path.chmod(0o600)
                try:
                    server = subprocess.Popen([self.binary, "--session", self.session, "server"],
                                              env=self._server_env(config_path),
                                              start_new_session=True, stdin=subprocess.DEVNULL,
                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except OSError as exc:
                    raise BackendError("herdr backend could not start dedicated server") from exc
                deadline = time.monotonic() + self.timeout
                while not self._running():
                    if server.poll() is not None or time.monotonic() >= deadline:
                        raise BackendError("herdr backend headless server did not become ready")
                    time.sleep(0.05)
                identity = self.verify_socket(self._reported_socket())
                owned = {"pid": server.pid, "start": process_start(server.pid),
                         "pid_ns": pid_namespace(), "socket": identity}
                if not owned["start"] or not owned["pid_ns"]:
                    raise BackendError("herdr server process identity is unavailable")
                receipt.write_text(json.dumps(owned))
                receipt.chmod(0o600)
                return owned

    def start_server(self):
        """Host-side idempotent server recovery, without creating a pane/record."""
        if os.environ.get("NOGG_OPENSPEC_FENCED") == "1":
            raise BackendError("herdr server start is host-only; run it from an unsandboxed shell")
        return self._ensure_server()

    def prepare(self, name, cwd):
        """Server/workspace/socket preconditions, before the caller writes a record."""
        owned = self._ensure_server()
        path = self._reported_socket()
        self.verify_socket(path)
        workspaces = self._json("workspace", "list")["workspaces"]
        matches = [w for w in workspaces if w.get("label") == self.slug]
        if len(matches) > 1:
            raise BackendError("herdr workspace label is ambiguous")
        workspace = (matches[0] if matches else self._json(
            "workspace", "create", "--label", self.slug, "--cwd", str(self.root), "--no-focus")["workspace"])
        self.verify_socket(path)
        self._prepared = {"name": name, "label": name, "herdr_session": self.session,
                          "workspace": workspace["workspace_id"], "socket_path": path,
                          "session_pid_ns": owned.get("pid_ns") or pid_namespace()}
        return dict(self._prepared)

    def _panes(self, ref=None):
        value = self._json("pane", "list", ref=ref)
        panes = value.get("panes")
        if not isinstance(panes, list) or not all(isinstance(p, dict) for p in panes):
            raise BackendError("herdr backend returned malformed pane list")
        return panes

    def _pane(self, ref, panes=None):
        if isinstance(ref, str):
            ref = {"label": ref}
        panes = self._panes(ref) if panes is None else panes
        label = ref.get("label", ref.get("name"))
        scoped = [p for p in panes if not ref.get("workspace")
                  or p.get("workspace_id") == ref["workspace"]]
        # Resolve the ID first; terminal/PID identity below prevents adoption
        # of a reused ID. Only a unique label can recover a changed pane ID.
        identified = [p for p in scoped if p.get("pane_id") == ref.get("pane_id")]
        if len(identified) == 1:
            return identified[0]
        matches = [p for p in scoped if p.get("label") == label]
        if len(matches) > 1:
            raise BackendError("herdr pane label is ambiguous")
        return matches[0] if matches else None

    def start(self, name, cwd, env, argv, log):
        ref = self._prepared if self._prepared and self._prepared["name"] == name else self.prepare(name, cwd)
        ref = dict(ref)
        self.verify_socket(ref["socket_path"])
        pane_env = dict(env, HERDR_AGENT={"antigravity": "agy"}.get(
            env.get("NOGG_SESSION_AGENT"), env.get("NOGG_SESSION_AGENT", "claude")))
        command = [str(self.recorder), log.path, str(log.max_bytes), str(log.rotation_depth), "--", *argv]
        request = {"id": str(uuid.uuid4()), "method": "layout.apply", "params": {
            "workspace_id": ref["workspace"], "tab_label": name,
            "root": {"type": "pane", "command": command, "cwd": str(cwd), "env": pane_env, "label": name}}}
        reply = None
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(self.timeout)
                client.connect(ref["socket_path"])
                deadline = time.monotonic() + self.timeout
                client.sendall((json.dumps(request) + "\n").encode())
                line = b""
                while b"\n" not in line and len(line) <= 1024 * 1024:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError()
                    client.settimeout(remaining)
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    line += chunk
                if len(line) > 1024 * 1024 or not line.endswith(b"\n"):
                    raise ValueError()
                reply = json.loads(line)
                if not isinstance(reply, dict) or reply.get("id") != request["id"]:
                    reply = None
        except (OSError, ValueError):
            pass
        if reply and isinstance(reply.get("error"), dict):
            code = reply["error"].get("code", "unknown_error")
            raise BackendError(f"herdr layout.apply failed ({code})")
        try:
            ref["pane_id"] = reply["result"]["layout"]["root"]["pane_id"]
            if not isinstance(ref["pane_id"], str):
                raise ValueError()
        except (TypeError, KeyError, ValueError):
            pane = self._pane(ref)
            if not pane:
                raise BackendError("herdr layout.apply reply lost or malformed; no unique pane found")
            ref["pane_id"] = pane["pane_id"]
        pane = self._pane(ref)
        if not pane or not isinstance(pane.get("terminal_id"), str) or not pane["terminal_id"]:
            raise BackendError("herdr pane terminal identity is unavailable")
        pid = self._process_pid(ref, pane)
        local = same_namespace(ref["session_pid_ns"])
        birth = process_start(pid) if local else None
        if local and not birth:
            raise BackendError("herdr pane root process identity is unavailable")
        ref.update(terminal_id=pane["terminal_id"], session_pid=pid, session_pid_start=birth)
        return ref

    def pid(self, ref):
        pane = self._pane(ref)
        if not pane:
            return None
        return self._process_pid(ref, pane)

    def _process_pid(self, ref, pane):
        info = self._json("pane", "process-info", "--pane", pane["pane_id"], ref=ref).get("process_info")
        pid = info.get("shell_pid") if isinstance(info, dict) else None
        if type(pid) is not int or pid <= 0:
            raise BackendError("herdr backend returned malformed process info")
        return pid

    def _identity(self, ref, pane):
        pid = self._process_pid(ref, pane)
        expected = ref.get("session_pid")
        birth = ref.get("session_pid_start")
        if not expected:
            return None
        if pid != expected:
            return False
        terminal = ref.get("terminal_id")
        if terminal and pane.get("terminal_id") != terminal:
            return False
        local = same_namespace(ref.get("session_pid_ns"))
        if terminal and (not local or not birth):
            return True
        if not local or not birth:
            return None
        actual = process_start(pid)
        if actual is None:
            return False if not Path(f"/proc/{pid}").exists() else None
        return actual == birth

    def live(self, records):
        alive, unknown = set(), set()
        groups = {}
        for rec in records:
            ref = dict(rec.get("backend_ref") or {"label": rec["name"]})
            for key in ("session_pid", "session_pid_start", "session_pid_ns"):
                if rec.get(key) is not None:
                    ref[key] = rec[key]
            groups.setdefault(ref.get("herdr_session", self.session), []).append((rec, ref))
        for namespace, group in groups.items():
            # A stopped dedicated server is definite evidence that none of its
            # panes can still be live, but require the status and session list
            # to agree. Every other failure remains unknown.
            try:
                status = self._cli("status", ref={"herdr_session": namespace})
                match = re.search(r"^server:\s*\n\s+status:\s*(running|not running)\s*$",
                                  status.stdout, re.M) if status.returncode == 0 else None
                if not match:
                    raise BackendError("herdr backend returned unrecognized server status")
                sessions = self._json("session", "list", "--json",
                                      ref={"herdr_session": namespace}).get("sessions")
                matches = [s for s in sessions if s.get("name") == namespace] if isinstance(sessions, list) else []
                if len(matches) != 1 or type(matches[0].get("running")) is not bool:
                    raise BackendError("herdr backend could not verify dedicated session status")
                listed_running = matches[0]["running"]
                status_running = match[1] == "running"
            except (BackendError, KeyError, TypeError):
                unknown.update(rec["name"] for rec, _ in group)
                continue
            if status_running != listed_running:
                unknown.update(rec["name"] for rec, _ in group)
                continue
            if not status_running:
                continue
            try:
                panes = self._panes({"herdr_session": namespace})
            except (BackendError, KeyError, TypeError):
                unknown.update(rec["name"] for rec, _ in group)
                continue
            for rec, ref in group:
                try:
                    pane = self._pane(ref, panes)
                    identity = self._identity(ref, pane) if pane else False
                    if identity is True:
                        alive.add(rec["name"])
                    elif identity is None:
                        unknown.add(rec["name"])
                except (BackendError, KeyError, TypeError):
                    unknown.add(rec["name"])
        return alive, unknown

    def exists(self, ref):
        try:
            pane = self._pane(ref)
            if not pane:
                return False
            return self._identity(ref, pane) is not False if isinstance(ref, dict) and ref.get("session_pid") else True
        except BackendError as exc:
            # Uncertainty must never be treated as absence for name collisions.
            if isinstance(ref, str) and "server_not_running" in str(exc):
                return False
            return True

    def _target(self, ref):
        pane = self._pane(ref)
        if not pane:
            raise BackendError("herdr session pane vanished")
        if isinstance(ref, dict) and ref.get("session_pid") and self._identity(ref, pane) is not True:
            raise BackendError("herdr session process identity changed or is unknown")
        return pane["pane_id"]

    def send_text(self, ref, text):
        self._cli("pane", "send-text", self._target(ref), text, ref=ref)

    def send_keys(self, ref, key, *, check=True):
        if key not in KEYS:
            raise ValueError(f"unsupported session key: {key!r}")
        try:
            self._cli("pane", "send-keys", self._target(ref),
                      "esc" if key == "escape" else key, ref=ref, check=check)
        except BackendError:
            if check:
                raise

    def capture(self, ref, attributes=False):
        result = self._cli("pane", "read", self._target(ref), "--source", "visible",
                           "--format", "ansi" if attributes else "text", ref=ref, check=False)
        return result.stdout if result.returncode == 0 else ""

    def kill(self, ref):
        pane = self._pane(ref)
        if pane:
            # The spike verified pane.close terminates the entire process tree.
            self._cli("pane", "close", pane["pane_id"], ref=ref)

    def attach_argv(self, ref, read_only=False):
        if read_only:
            raise BackendError("herdr has no read-only client; use session log --follow")
        return [self.binary, "--session", ref.get("herdr_session", self.session),
                "agent", "attach", self._target(ref)]

    def agent_status(self, ref):
        try:
            value = self._json("agent", "get", self._target(ref), ref=ref)["agent"]["agent_status"]
            return value if value in {"idle", "working", "blocked", "done", "unknown"} else "unknown"
        except (BackendError, KeyError, TypeError):
            return "unknown"

    def idle_shutdown(self):
        pass

    def wire_log(self, ref, log, *, check=True):
        pass  # Recorder owns logging for the pane's entire lifetime.

    def orphans(self, records):
        """Return only unowned Nogging-labelled panes in this repo's workspace."""
        groups = {}
        for rec in records:
            namespace = (rec.get("backend_ref") or {}).get("herdr_session", self.session)
            groups.setdefault(namespace, []).append(rec)
        orphans = []
        for namespace, group in groups.items():
            active = [r for r in group if r.get("state") in {"starting", "running", "idle"}]
            alive, unknown = self.live(active)
            if unknown:
                continue
            owned = alive | {r["name"] for r in active if r.get("state") == "starting"}
            ref = {"herdr_session": namespace}
            try:
                workspaces = self._json("workspace", "list", ref=ref)["workspaces"]
                ids = {w["workspace_id"] for w in workspaces if w.get("label") == self.slug}
                orphans.extend({"name": p["label"], "label": p["label"], "pane_id": p["pane_id"],
                                "workspace": p["workspace_id"], "herdr_session": namespace}
                               for p in self._panes(ref) if p.get("workspace_id") in ids
                               and str(p.get("label", "")).startswith("sf-") and p["label"] not in owned)
            except (BackendError, KeyError, TypeError):
                continue
        return orphans

    def liveness_probe(self, ref):
        # Read the record at probe time: the initial reservation precedes exec
        # and therefore cannot yet contain the recorder's PID/birth token.
        record = self.record_dir / f"{ref.get('name', ref.get('label'))}.json"
        return {"backend": self.name, "argv": [sys.executable, str(Path(__file__).resolve()),
                "--probe", self.binary, str(record)]}


def main():
    if len(sys.argv) != 4 or sys.argv[1] != "--probe":
        return 2
    try:
        rec = json.loads(Path(sys.argv[3]).read_text())
        backend = HerdrBackend({"session_herdr_command": sys.argv[2]},
                               lambda *args, check=False, **kw: subprocess.run(args, text=True, capture_output=True, **kw))
        alive, unknown = backend.live([rec])
        return 0 if alive else (2 if unknown else 1)
    except (OSError, ValueError, BackendError, KeyError, TypeError):
        return 2


if __name__ == "__main__":
    sys.exit(main())
