"""The consented dashboard service of `nogg dashboard service` and `nogg dashboard status`.

The operator's consent record, the append-only audit trail, the user unit's text and the
`enable`, `disable`, `run` and `status` steps live here. Every host effect goes through a
`Host`: `systemctl`, `loginctl` and `systemd-cat` are called through its runner, so tests
put stubs on PATH or pass their own. The facts about the caller (supervised session,
operator terminal, cgroup) are decided by `scripts/nogg` and passed in.

Nothing written here holds the secret: the unit runs `nogg dashboard service run`, which
reads the secret file itself, and the consent names only the address the operator typed.
"""
from __future__ import annotations

import datetime as dt
import getpass, json, os, re, shutil, socket, stat, struct, subprocess, threading, time
from dataclasses import dataclass
from pathlib import Path

import dashboard_security as sec

SCHEMA = "nogg.dashboard.consent/v1"
EX_CONFIG = 78                       # a refusal that waiting cannot cure: not restarted
SOCKET_PATH_LIMIT = 107              # sun_path minus its terminating byte on Linux
CONSENT_KEYS = frozenset({"schema", "bind", "port", "allow_hosts", "at", "tty"})
CONSENT_MAX_BYTES = 4096
JOURNAL_TAG = "nogg-dashboard"
CONTROL_MAX_BYTES = 1024             # one request line, read within CONTROL_DEADLINE
CONTROL_DEADLINE = 2.0
CONTROL_POLL = 0.2                   # how often the accept loop looks at its stop event
CLIENT_TIMEOUT = 10.0                # a CLI waits behind at most a few slow clients
_CALLER_LABEL = re.compile(r"^(?:operator|orchestrator:[A-Za-z0-9._-]{1,100})$")
_UCRED = struct.Struct("3i")         # struct ucred: pid, uid, gid, in this order
_AT_FORM = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
_TTY_FORM = re.compile(r"^/dev/[A-Za-z0-9._/-]{1,64}$")
_USER_MANAGER = re.compile(r"^user@[0-9]+\.service$")
# The only fields each audit event may hold (design Decision 10). A code, the secret, a
# cookie or a full hash has no field here, so none can reach the trail by mistake.
EVENT_FIELDS = {
    "consent": ("bind", "port", "tty"),
    "revoked": ("caller",),
    "started": ("mode", "bind", "port", "pid", "consent_at", "tty"),
    "stopped": (),
    "link_minted": ("caller", "peer_pid", "expires_at", "id"),
    "link_redeemed": ("id", "peer"),
    "link_replayed": ("id", "peer", "same_peer"),
    "rotated": (),
}

UNIT_TEMPLATE = """\
[Unit]
Description=Nogging dashboard on a consented private address ({{NAME}})
After=default.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory={{WORKDIR}}
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
UMask=0077
LimitCORE=0
ExecStart="{{WORKDIR}}/scripts/nogg" dashboard service run
Restart=on-failure
RestartSec=30
RestartPreventExitStatus=78 203

[Install]
WantedBy=default.target
"""


class ServiceRefused(RuntimeError):
    """A refused step; `code` is the exit status (78 when waiting cannot cure it)."""

    def __init__(self, message, code=1, reason=None):
        super().__init__(message)
        self.code, self.reason = code, reason or message


def _run(argv, input=None):
    try:
        return subprocess.run(argv, text=True, capture_output=True, input=input, timeout=60, check=False)
    except (OSError, subprocess.SubprocessError) as exc:
        return subprocess.CompletedProcess(argv, 127, "", str(exc))


@dataclass
class Host:
    """The host commands this module calls; tests replace either."""
    run: object = _run
    which: object = shutil.which

    def systemctl(self, *args):
        return self.run(["systemctl", "--user", *args])

    def has_systemctl(self):
        return self.which("systemctl") is not None


@dataclass(frozen=True)
class Paths:
    """Where the service's files live, all from the canonical checkout."""
    state: Path            # <canonical>/.nogging/state/dashboard
    unit_dir: Path         # the user unit directory
    slug: str
    workdir: Path          # the canonical checkout
    name: str = ""

    @property
    def consent(self):
        return self.state / "consent.json"

    @property
    def audit(self):
        return self.state / "audit.jsonl"

    @property
    def secret(self):
        return self.state / "secret"

    @property
    def control(self):
        return self.state / "control.sock"

    @property
    def unit_name(self):
        return f"nogg-dashboard-{self.slug}.service"

    @property
    def unit_path(self):
        return self.unit_dir / self.unit_name


def user_unit_dir(environ=os.environ):
    config = environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(config) / "systemd/user"


def now_iso(clock=None):
    moment = clock() if clock else dt.datetime.now(dt.timezone.utc)
    return moment.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def bind_text(bind):
    """A `Bind` as the operator types it: the zone of a link-local address included."""
    return f"{bind.address}%{bind.zone}" if bind.zone else bind.address


# --- the unit ---------------------------------------------------------------------

def _unit_value(text, what):
    """A value for the unit file: `%` escaped, and refused where systemd would read it
    differently. WorkingDirectory= takes its path verbatim (systemd refuses it quoted),
    ExecStart= quotes it and expands `$`, so a quote, a backslash, a dollar sign or a
    control character has no safe form."""
    text = str(text)
    if any(ch in text for ch in '"\\$') or any(ord(ch) < 32 or ord(ch) == 127 for ch in text) \
            or text != text.strip():
        raise ServiceRefused(f"refusing to write the dashboard unit: the {what} {text!r} holds a quote, "
                             "a backslash, a dollar sign, a control character or edge whitespace, which a unit file "
                             "cannot carry safely; move the checkout to a plain path")
    return text.replace("%", "%%")


def render_unit(name, workdir):
    workdir = Path(workdir)
    if not workdir.is_absolute():
        raise ServiceRefused(f"refusing to write the dashboard unit: {workdir} is not an absolute path")
    return (UNIT_TEMPLATE.replace("{{NAME}}", _unit_value(name, "repository name"))
            .replace("{{WORKDIR}}", _unit_value(workdir, "checkout path")))


# --- the consent record -----------------------------------------------------------

def consent_record(bind, port, allow_hosts, at, tty):
    return {"schema": SCHEMA, "bind": bind, "port": port, "allow_hosts": list(allow_hosts), "at": at, "tty": tty}


def write_consent(path, record):
    """Write the record atomically: a fresh `0600` file in the `0700` directory, synced,
    then renamed over the old one."""
    path = Path(path)
    sec._prepare_directory(path)
    temporary = path.with_name(path.name + ".new")
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    sec._sync_directory(path.parent)


def read_consent(path):
    """The consent record, checked: a regular `0600` file owned by the operator in the
    `0700` directory, the exact schema, and a bind and allow-hosts the bind policy accepts
    again today. Anything else raises `ServiceRefused` with exit 78 and the remedy."""
    path = Path(path)
    remedy = ("run `nogg dashboard service enable --bind <address>` on a terminal to record a new consent, "
              "or `nogg dashboard service disable` to end the exposure")

    def refused(reason):
        return ServiceRefused(f"refusing the dashboard service: {reason}; {remedy}", EX_CONFIG, reason)

    try:
        sec._check_directory(path.parent)
    except FileNotFoundError:
        raise refused(f"no consent is recorded at {path}") from None
    except sec.SecretRefused as exc:
        raise refused(str(exc)) from None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise refused(f"no consent is recorded at {path}") from None
    except OSError as exc:
        raise refused(f"{path} cannot be read ({exc.__class__.__name__}); it must be a regular file") from None
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise refused(f"{path} is not a regular file")
        if stat.S_IMODE(info.st_mode) & 0o077:
            raise refused(f"{path} has mode {stat.S_IMODE(info.st_mode):04o}, wider than the required 0600")
        if info.st_uid != os.geteuid():
            raise refused(f"{path} belongs to another user")
        raw = handle.read(CONSENT_MAX_BYTES + 1)
    try:
        record = json.loads(raw.decode("utf-8")) if len(raw) <= CONSENT_MAX_BYTES else None
    except ValueError:
        record = None
    if not isinstance(record, dict) or set(record) != CONSENT_KEYS or record.get("schema") != SCHEMA:
        raise refused(f"{path} does not match the schema {SCHEMA}")
    port, hosts = record["port"], record["allow_hosts"]
    if type(port) is not int or not 1 <= port <= 65535:
        raise refused(f"{path} names no valid port")
    if not isinstance(hosts, list) or not all(isinstance(h, str) for h in hosts) \
            or not all(isinstance(record[k], str) for k in ("bind", "at", "tty")) \
            or not _AT_FORM.match(record["at"]) or not _TTY_FORM.match(record["tty"]):
        raise refused(f"{path} does not match the schema {SCHEMA}")
    try:
        bind = sec.check_bind(record["bind"])
        for value in hosts:
            sec.check_allow_host(value)
    except (sec.BindRefused, ValueError) as exc:
        raise refused(f"the recorded consent no longer passes the bind policy: {exc}") from None
    if bind.loopback:
        raise refused("the recorded consent names a loopback address, which needs no service")
    return record


def consent_problem(path):
    """Why the consent at `path` is unusable, or None. Nothing is created or changed."""
    try:
        read_consent(path)
    except ServiceRefused as exc:
        return exc.reason
    return None


# --- the audit trail --------------------------------------------------------------

def audit_line(event, fields, at):
    allowed = EVENT_FIELDS.get(event)
    if allowed is None:
        raise ValueError(f"unknown audit event {event!r}")
    extra = set(fields) - set(allowed)
    if extra:
        raise ValueError(f"audit event {event} takes no field {', '.join(sorted(extra))}")
    return json.dumps({"at": at, "event": event, **fields}, separators=(",", ":"))


def journal_sender(host):
    """A CLI's copy into the journal through `systemd-cat`, where the host has one. The
    journal is a second witness; a host without it keeps the file alone."""
    if host.which("systemd-cat") is None:
        return None
    return lambda line: host.run(["systemd-cat", "-t", JOURNAL_TAG], input=line + "\n")


class Audit:
    """`audit.jsonl`: one `write()` of one line on an `O_APPEND` descriptor, mode `0600`.
    `mirror` gets each line even when the file cannot take it (the service's stdout,
    which is the journal); `journal` gets it after a successful write."""

    def __init__(self, path, *, clock=None, mirror=None, journal=None):
        self.path, self.clock, self.mirror, self.journal = Path(path), clock, mirror, journal

    def append(self, event, **fields):
        line = audit_line(event, fields, now_iso(self.clock))
        try:
            self._write(line)
        finally:
            if self.mirror is not None:
                print(line, file=self.mirror, flush=True)
        if self.journal is not None:
            try:
                self.journal(line)
            except Exception:
                pass
        return line

    def _write(self, line):
        sec._prepare_directory(self.path)
        data = (line + "\n").encode()
        fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
                raise OSError(f"{self.path} is not a regular file of the operator")
            if stat.S_IMODE(info.st_mode) & 0o077:
                os.fchmod(fd, 0o600)
            if os.write(fd, data) != len(data):
                raise OSError(f"{self.path} took a partial line")
        finally:
            os.close(fd)


def audit_tail(path, count=10):
    """The last `count` lines of the trail; nothing is created."""
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            handle.seek(max(0, handle.tell() - 64 * 1024))
            lines = handle.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return []
    return [line for line in lines if line.strip()][-count:]


# --- host facts -------------------------------------------------------------------

def linger_on(host, user=None):
    res = host.run(["loginctl", "show-user", user or getpass.getuser(), "--property=Linger"])
    return res.returncode == 0 and res.stdout.strip().endswith("=yes")


def unit_state(paths, host):
    """`(enabled, active)` from `systemctl --user is-enabled|is-active`, each a word or
    `unknown` where the host has no systemctl."""
    if not host.has_systemctl():
        return "unknown", "unknown"
    words = []
    for verb in ("is-enabled", "is-active"):
        res = host.systemctl(verb, paths.unit_name)
        words.append((res.stdout or "").strip().splitlines()[-1:][0] if (res.stdout or "").strip() else "unknown")
    return tuple(words)


def in_unit_cgroup(text, unit_name):
    """Whether cgroup text puts this process in the unit's own cgroup, directly under
    the user manager (`user@<uid>.service/[app.slice/]<unit>`)."""
    parts = (sec.systemd_cgroup(text) or "").rstrip("/").split("/")
    if len(parts) < 2 or parts[-1] != unit_name:
        return False
    parent = parts[-2]
    if parent == "app.slice" and len(parts) >= 3:
        parent = parts[-3]
    return _USER_MANAGER.match(parent) is not None


def socket_path_warning(paths):
    length = len(os.fsencode(str(paths.control)))
    if length <= SOCKET_PATH_LIMIT:
        return None
    return (f"WARNING: the control socket path {paths.control} is {length} bytes, longer than the "
            f"{SOCKET_PATH_LIMIT} this platform allows; the service will serve, but `nogg dashboard pair` "
            "cannot reach it. A shorter checkout path avoids this.")


def journal_persistent(root=Path("/var/log/journal")):
    return root.is_dir()


# --- the steps --------------------------------------------------------------------

@dataclass
class Caller:
    """What `scripts/nogg` proved about the caller."""
    refusal: str | None = None          # why it is not an operator terminal, or None
    session: dict | None = None         # the proven supervised session, or None
    session_error: str | None = None    # an unproven session name
    stdout_tty: bool = False


def enable(paths, host, caller, *, address, port, allow_hosts, confirm, out, nat_warning=None,
           clock=None, user=None):
    """`service enable`: the operator's consent, typed at a login terminal. `confirm`
    reads one line from the terminal and returns `(line, terminal name)`. Every refusal
    comes before anything is written and before any `systemctl` call."""
    if caller.refusal:
        raise ServiceRefused(f"refusing `nogg dashboard service enable` outside an operator terminal: "
                             f"{caller.refusal}. Run it yourself on a login terminal (`ssh -t` from another host)")
    if not caller.stdout_tty:
        raise ServiceRefused("refusing `nogg dashboard service enable`: stdout is not a terminal; run it on a "
                             "terminal without a pipe or a redirect")
    bind = sec.check_bind(address)
    if bind.loopback:
        raise ServiceRefused(f"refusing `nogg dashboard service enable --bind {address}`: a loopback address "
                             "needs no service; run `nogg dashboard` instead")
    hosts = [sec.check_allow_host(value) for value in allow_hosts]
    if not host.has_systemctl():
        raise ServiceRefused("refusing `nogg dashboard service enable`: this host has no `systemctl`, so no user "
                             f"service can run. Run `nogg dashboard --bind {address}` on a login terminal instead")
    unit_text = render_unit(paths.name or paths.workdir.name, paths.workdir)
    problem = sec.mode_problem(paths.secret)
    if problem:
        raise ServiceRefused(f"refusing `nogg dashboard service enable`: {problem}; replace it with "
                             "`nogg dashboard --rotate-token` first")
    print(f"This lets {paths.unit_name} serve the dashboard on http://{bind.host}:{port}/ whenever you are "
          "logged in, without a terminal. Phones sign in with a one-time pairing link from "
          "`nogg dashboard pair`; `nogg dashboard service disable` ends it.", file=out)
    for warning in (sec.plain_http_warning(bind), nat_warning, socket_path_warning(paths)):
        if warning:
            print(warning, file=out)
    print(f"Type the address ({address}) to confirm:", file=out, flush=True)
    typed, tty = confirm()
    if (typed or "").strip() != address:
        raise ServiceRefused("the typed line does not match the address; nothing was written")
    replacing = os.path.lexists(paths.consent) or unit_state(paths, host)[1] == "active"
    at = now_iso(clock)
    record = consent_record(bind_text(bind), port, hosts, at, tty)
    try:
        sec.ensure_secret(paths.secret)
    except sec.SecretRefused as exc:
        raise ServiceRefused(f"refusing `nogg dashboard service enable`: {exc}") from None
    write_consent(paths.consent, record)
    try:
        Audit(paths.audit, clock=clock, journal=journal_sender(host)).append(
            "consent", bind=record["bind"], port=port, tty=tty)
    except OSError as exc:
        os.unlink(paths.consent)
        raise ServiceRefused(f"refusing `nogg dashboard service enable`: the consent cannot be recorded in "
                             f"{paths.audit} ({exc.__class__.__name__}); nothing is enabled") from None
    write_unit(paths, unit_text)
    for args in (("daemon-reload",), ("enable", "--now", paths.unit_name)) + \
            ((("restart", paths.unit_name),) if replacing else ()):
        res = host.systemctl(*args)
        if res.returncode != 0:
            raise ServiceRefused(f"`systemctl --user {' '.join(args)}` failed: {(res.stderr or '').strip()}; "
                                 "the consent is recorded, so fix the cause and run `systemctl --user start "
                                 f"{paths.unit_name}`, or end it with `nogg dashboard service disable`")
    print(f"enabled {paths.unit_name} for {record['bind']} port {port}; the consent is in {paths.consent}",
          file=out)
    if not linger_on(host, user):
        print(f"NOTE: user lingering is off, so the service stops when you log out; "
              f"`loginctl enable-linger {user or getpass.getuser()}` keeps it running", file=out)
    return record


def write_unit(paths, text):
    """The unit file, through a fresh temporary file that follows no link."""
    paths.unit_dir.mkdir(parents=True, exist_ok=True)
    temporary = paths.unit_path.with_name(paths.unit_name + ".new")
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "w") as handle:
        handle.write(text)
    os.replace(temporary, paths.unit_path)


def acting_caller(caller, command, only):
    """The audit label of a caller that is the operator at a terminal or the proven
    Orchestration Agent (`operator`, `orchestrator:<name>`), or a refusal naming `only`."""
    if caller.session_error:
        raise ServiceRefused(f"refusing {command}: {caller.session_error}")
    if caller.session is not None:
        if caller.session.get("role") == "orchestrator":
            return f"orchestrator:{caller.session.get('name')}"
        raise ServiceRefused(f"refusing {command} inside supervised session {caller.session.get('name')}: {only}")
    if caller.refusal:
        raise ServiceRefused(f"refusing {command} outside an operator terminal: {caller.refusal}")
    return "operator"


def disable_caller(caller):
    """The audit label of a caller allowed to end the exposure, or a refusal."""
    return acting_caller(caller, "`nogg dashboard service disable`",
                         "only the operator at a terminal or the Orchestration Agent ends the dashboard exposure")


def disable(paths, host, caller, *, out, clock=None):
    """`service disable`: stop, disable and remove the unit, delete the consent, record
    `revoked`. Nothing enabled is success and changes nothing."""
    label = disable_caller(caller)
    present = [p for p in (paths.unit_path, paths.consent) if os.path.lexists(p)]
    enabled, active = unit_state(paths, host)
    loaded = os.path.lexists(paths.unit_path) or enabled in ("enabled", "enabled-runtime") or active == "active"
    if not present and not loaded:
        print("the dashboard service is not enabled; nothing to disable", file=out)
        return False
    if loaded and host.has_systemctl():
        res = host.systemctl("disable", "--now", paths.unit_name)
        if res.returncode != 0:
            if os.path.lexists(paths.consent):
                os.unlink(paths.consent)       # a restart now refuses with exit 78
            raise ServiceRefused(f"`systemctl --user disable --now {paths.unit_name}` failed: "
                                 f"{(res.stderr or '').strip() or 'no reason given'}; the consent is removed, so a "
                                 f"restart refuses, but the service may still run. Stop it with `systemctl --user "
                                 f"stop {paths.unit_name}` and run `nogg dashboard service disable` again")
    for path in present:
        os.unlink(path)
    if host.has_systemctl():
        host.systemctl("daemon-reload")
    Audit(paths.audit, clock=clock, journal=journal_sender(host)).append("revoked", caller=label)
    print(f"disabled {paths.unit_name}: the unit and the consent are gone; a new exposure needs "
          "`nogg dashboard service enable` on a terminal", file=out)
    return True


def run(paths, caller, *, cgroup, serve, out, clock=None):
    """`service run`, what the unit starts: the session refusal, the unit's own cgroup,
    a valid consent, then exactly the consented values. No token, no link. After the TCP
    bind it opens the control socket that `nogg dashboard pair` and `status` talk to."""
    if caller.session_error:
        raise ServiceRefused(f"refusing `nogg dashboard service run`: {caller.session_error}", EX_CONFIG)
    if caller.session is not None:
        raise ServiceRefused("refusing `nogg dashboard service run` inside a supervised session: the token "
                             "would reach the session log, and network exposure stays an operator act",
                             EX_CONFIG)
    text = cgroup()
    if text is not None and not in_unit_cgroup(text, paths.unit_name):
        raise ServiceRefused(f"refusing `nogg dashboard service run` outside {paths.unit_name} (cgroup "
                             f"{sec.systemd_cgroup(text) or '(none)'}): only the user unit starts it; use "
                             f"`systemctl --user start {paths.unit_name}`", EX_CONFIG)
    consent = read_consent(paths.consent)
    bind = sec.check_bind(consent["bind"])
    audit = Audit(paths.audit, clock=clock, mirror=out)

    def started(port):
        audit.append("started", mode="service", bind=consent["bind"], port=port, pid=os.getpid(),
                     consent_at=consent["at"], tty=consent["tty"])

    def stopped():
        try:
            audit.append("stopped")
        except OSError as exc:
            print(f"WARNING: cannot append to {paths.audit}: {exc.__class__.__name__}", file=out, flush=True)

    serve(bind, consent["port"], consent["allow_hosts"], on_start=started, on_stop=stopped,
          audit=audit.append, control=control_opener(paths, out))


def status(paths, host, *, out, cgroup_applies, journal_is_persistent, request=None):
    """`nogg dashboard status`: what is consented, enabled and recorded. Writes nothing."""
    problem = consent_problem(paths.consent) if os.path.lexists(paths.consent) else None
    if not os.path.lexists(paths.consent):
        print("consent: no exposure is consented", file=out)
    elif problem:
        print(f"consent: INVALID — {problem}", file=out)
    else:
        record = json.loads(Path(paths.consent).read_text())
        hosts = f", also answering {', '.join(record['allow_hosts'])}" if record["allow_hosts"] else ""
        print(f"consent: {record['bind']} port {record['port']}{hosts}, since {record['at']} from {record['tty']}",
              file=out)
    enabled, active = unit_state(paths, host)
    print(f"unit: {paths.unit_name} {'exists' if paths.unit_path.exists() else 'absent'}, "
          f"enabled={enabled}, active={active}", file=out)
    print(f"service: {running_report(paths, request)}", file=out)
    print(f"cgroup test: {'applies' if cgroup_applies else 'does not apply on this host'}; "
          f"journal: {'persistent' if journal_is_persistent else 'volatile (lost at reboot)'}", file=out)
    lines = audit_tail(paths.audit)
    print("last events:" if lines else "last events: none recorded", file=out)
    for line in lines:
        print(f"  {line}", file=out)


def doctor_lines(paths, host):
    """`(warnings, notes)` about the service. Silent on a repository that never used the
    dashboard: only file checks run until a secret, a consent or a unit exists."""
    used = any(os.path.lexists(p) for p in (paths.secret, paths.consent, paths.unit_path))
    if not used:
        return [], []
    warnings, notes = [], []
    has_consent = os.path.lexists(paths.consent)
    problem = consent_problem(paths.consent) if has_consent else None
    enabled, active = unit_state(paths, host)
    unit_on = paths.unit_path.exists() or enabled in ("enabled", "enabled-runtime") or active == "active"
    if has_consent and problem:
        warnings.append(f"dashboard consent: {problem}; end the exposure with `nogg dashboard service disable` "
                        "or record it again with `nogg dashboard service enable` on a terminal")
    if unit_on and (not has_consent or problem):
        warnings.append(f"dashboard: {paths.unit_name} exists or runs without a valid consent; run "
                        "`nogg dashboard service disable`")
    elif unit_on:
        record = json.loads(Path(paths.consent).read_text())
        notes.append(f"dashboard: {paths.unit_name} serves {record['bind']} port {record['port']} "
                     f"(consented {record['at']} from {record['tty']}; enabled={enabled}, active={active})")
    elif has_consent and not problem:
        notes.append(f"dashboard: a consent is recorded but {paths.unit_name} is not installed; run "
                     "`nogg dashboard service enable` on a terminal or `nogg dashboard service disable`")
    return warnings, notes


# --- the control socket (design Decision 8) ----------------------------------------

class ControlUnreachable(RuntimeError):
    """No running service answers on the control socket; the message says why."""


def peer_credentials(connection):
    """`(pid, uid, gid)` of a Unix socket peer, in the kernel's `struct ucred` order.
    session_backend_tmux.py reads the same option with the fields swapped (discovery S1 on
    SPEC-iohv); this reading must not copy that."""
    return _UCRED.unpack(connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, _UCRED.size))


def control_path_problem(path):
    """Why the control socket cannot be opened at `path`, or None. A socket that refuses
    connections is stale and removed; a non-socket or a live socket is never touched."""
    length = len(os.fsencode(str(path)))
    if length > SOCKET_PATH_LIMIT:
        return (f"the control socket path {path} is {length} bytes, longer than the {SOCKET_PATH_LIMIT} this "
                "platform allows")
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISSOCK(info.st_mode):
        return f"{path} is not a socket, and it is left in place"
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(CONTROL_DEADLINE)
    try:
        probe.connect(str(path))
    except (ConnectionRefusedError, FileNotFoundError):
        pass                                    # nobody listens: a stale socket
    except OSError as exc:
        return f"{path} cannot be checked ({exc.__class__.__name__}), and it is left in place"
    else:
        return f"another dashboard answers on {path}, and its socket is left in place"
    finally:
        probe.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    return None


class ControlServer:
    """The service's Unix stream socket: mode `0600` in the `0700` state directory, one
    connection at a time, a peer of the server's own uid only, one JSON line of at most
    CONTROL_MAX_BYTES within CONTROL_DEADLINE in, one JSON line out, then close. The accept
    loop wakes every CONTROL_POLL to look at its stop event, so a stop removes the socket."""

    def __init__(self, path, answer, *, uid=None, credentials=peer_credentials, deadline=CONTROL_DEADLINE,
                 poll=CONTROL_POLL, clock=time.monotonic):
        self.path, self.answer = Path(path), answer
        self.uid = os.geteuid() if uid is None else uid
        self.credentials, self.deadline, self.poll, self.clock = credentials, deadline, poll, clock
        self._stop, self._thread, self._socket, self._identity = threading.Event(), None, None, None

    def open(self):
        """Bind, listen and start the accept loop; returns `close`."""
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(self.path))
            os.chmod(self.path, 0o600)
            self._identity = os.lstat(self.path).st_ino
            listener.listen(8)
            listener.settimeout(self.poll)
        except BaseException:
            listener.close()
            raise
        self._socket = listener
        self._thread = threading.Thread(target=self._loop, name="dashboard-control", daemon=True)
        self._thread.start()
        return self.close

    def close(self):
        """Stop the loop, close the socket and remove it, unless another file took its place."""
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=self.deadline + self.poll + 1)
        if self._socket is not None:
            self._socket.close()
        try:
            if os.lstat(self.path).st_ino == self._identity:
                os.unlink(self.path)
        except FileNotFoundError:
            pass

    def _loop(self):
        while not self._stop.is_set():
            try:
                connection, _ = self._socket.accept()
            except socket.timeout:
                continue
            except OSError:
                if self._stop.is_set():
                    return
                continue
            with connection:
                try:
                    self._serve(connection)
                except OSError:
                    pass                        # the client went away

    def _serve(self, connection):
        pid, uid, _ = self.credentials(connection)
        if uid != self.uid:
            return                              # another user: closed without an answer
        request = self._read(connection)
        if request is None:
            return
        reply = self.answer(request, pid)
        connection.settimeout(self.deadline)
        connection.sendall(json.dumps(reply, sort_keys=True).encode() + b"\n")

    def _read(self, connection):
        """One JSON object line, or None for a client that is slow, sends too much or sends
        anything else."""
        end, data = self.clock() + self.deadline, b""
        while b"\n" not in data:
            left = end - self.clock()
            if left <= 0:
                return None
            connection.settimeout(left)
            try:
                chunk = connection.recv(CONTROL_MAX_BYTES + 1 - len(data))
            except socket.timeout:
                return None
            if not chunk:
                break
            data += chunk
            if len(data) > CONTROL_MAX_BYTES:
                return None
        try:
            request = json.loads(data.split(b"\n", 1)[0].decode("utf-8"))
        except ValueError:
            return None
        return request if isinstance(request, dict) else None


def control_answer(server):
    """The two operations of the control socket, answered from the running `server`. A
    reply holds the minted link or the status, never a code hash, the secret or a cookie."""
    def answer(request, pid):
        op = request.get("op")
        if op == "status":
            return {"ok": True, **server.pairing_status()}
        if op != "pair":
            return {"error": "unknown operation"}
        caller = request.get("caller")
        if not isinstance(caller, str) or not _CALLER_LABEL.match(caller):
            return {"error": "the caller label is malformed"}
        try:
            return {"ok": True, **server.mint_link(caller, pid)}
        except sec.PairingUnavailable as exc:
            return {"error": str(exc)}
        except (OSError, ValueError) as exc:
            return {"error": f"link_minted cannot be written to the audit trail ({exc.__class__.__name__}); "
                             "no link was minted"}
    return answer


def control_opener(paths, out):
    """`control(server)` for `serve`: opens the socket after the TCP bind and returns the
    call that closes it. A path that is taken or too long leaves the service serving
    without pairing, and says why."""
    def open_control(server):
        problem = control_path_problem(paths.control)
        if problem is None:
            try:
                return ControlServer(paths.control, control_answer(server)).open()
            except OSError as exc:
                problem = f"{paths.control} cannot be opened ({exc.__class__.__name__})"
        print(f"WARNING: serving without pairing: {problem}", file=out, flush=True)
        return None
    return open_control


def control_request(path, request, *, timeout=CLIENT_TIMEOUT):
    """One request to the running service and its reply; ControlUnreachable when no
    service answers."""
    if len(os.fsencode(str(path))) > SOCKET_PATH_LIMIT:
        raise ControlUnreachable(f"the control socket path {path} is longer than {SOCKET_PATH_LIMIT} bytes")
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    data = b""
    try:
        client.connect(str(path))
        client.sendall(json.dumps(request).encode() + b"\n")
        while b"\n" not in data and len(data) < 64 * 1024:
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
    except (FileNotFoundError, ConnectionRefusedError):
        raise ControlUnreachable(f"no dashboard service answers on {path}") from None
    except OSError as exc:
        raise ControlUnreachable(f"the dashboard service on {path} did not answer ({exc.__class__.__name__})") \
            from None
    finally:
        client.close()
    try:
        reply = json.loads(data.split(b"\n", 1)[0].decode("utf-8"))
    except ValueError:
        reply = None
    if not isinstance(reply, dict):
        raise ControlUnreachable(f"the dashboard service on {path} closed the connection without an answer")
    return reply


def pair(paths, caller, *, out, request=control_request):
    """`nogg dashboard pair` (design Decision 9): the caller rule first, so a refused caller
    never connects; then one link and its expiry on stdout, terminal or not."""
    label = acting_caller(caller, "`nogg dashboard pair`",
                          "only the operator at a terminal or the Orchestration Agent mints a pairing link")
    try:
        reply = request(paths.control, {"op": "pair", "caller": label})
    except ControlUnreachable as exc:
        raise ServiceRefused(f"no running dashboard service minted a link: {exc}. The operator enables it once "
                             "with `nogg dashboard service enable --bind <address>` on a login terminal") from None
    if not reply.get("ok") or not isinstance(reply.get("link"), str):
        raise ServiceRefused(f"the dashboard service minted no link: {str(reply.get('error'))[:300]}")
    print(reply["link"], file=out)
    ended = reply.get("ended") if type(reply.get("ended")) is int else 0
    note = f"; it ended {ended} older open link{'s' if ended != 1 else ''}" if ended else ""
    print(f"expires at {reply.get('expires_at')} (one use, five minutes){note}", file=out, flush=True)
    return reply


def running_report(paths, request=None):
    """What the running service says over the control socket, as one line; writes nothing."""
    request = request or control_request
    try:
        info = os.lstat(paths.control)
    except FileNotFoundError:
        info = None
    except OSError as exc:
        return f"{paths.control} cannot be read ({exc.__class__.__name__})"
    if info is not None and not stat.S_ISSOCK(info.st_mode):
        return f"{paths.control} is not a socket, so a running service serves without pairing"
    try:
        reply = request(paths.control, {"op": "status"})
    except ControlUnreachable as exc:
        return f"not reachable: {exc}"
    if not reply.get("ok"):
        return f"answered without a status: {str(reply.get('error'))[:300]}"
    links = reply.get("open_links")
    earliest = f", the earliest expires at {reply.get('earliest_expiry')}" if reply.get("earliest_expiry") else ""
    pairing = f"{links} open pairing link{'s' if links != 1 else ''}{earliest}" if reply.get("pairing") \
        else "no pairing"
    return f"running on {reply.get('bind')} port {reply.get('port')} since {reply.get('started_at')}; {pairing}"


def service_answers(paths, request=None):
    """Whether a running service answers on the control socket."""
    try:
        return bool((request or control_request)(paths.control, {"op": "status"}).get("ok"))
    except ControlUnreachable:
        return False
