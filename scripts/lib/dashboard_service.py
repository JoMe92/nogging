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
import getpass, json, os, re, shutil, stat, subprocess
from dataclasses import dataclass
from pathlib import Path

import dashboard_security as sec

SCHEMA = "nogg.dashboard.consent/v1"
EX_CONFIG = 78                       # a refusal that waiting cannot cure: not restarted
SOCKET_PATH_LIMIT = 107              # sun_path minus its terminating byte on Linux
CONSENT_KEYS = frozenset({"schema", "bind", "port", "allow_hosts", "at", "tty"})
CONSENT_MAX_BYTES = 4096
JOURNAL_TAG = "nogg-dashboard"
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


def disable_caller(caller):
    """The audit label of a caller allowed to end the exposure, or a refusal."""
    if caller.session_error:
        raise ServiceRefused(f"refusing `nogg dashboard service disable`: {caller.session_error}")
    if caller.session is not None:
        if caller.session.get("role") == "orchestrator":
            return f"orchestrator:{caller.session.get('name')}"
        raise ServiceRefused(f"refusing `nogg dashboard service disable` inside supervised session "
                             f"{caller.session.get('name')}: only the operator at a terminal or the "
                             "Orchestration Agent ends the dashboard exposure")
    if caller.refusal:
        raise ServiceRefused(f"refusing `nogg dashboard service disable` outside an operator terminal: "
                             f"{caller.refusal}")
    return "operator"


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
    a valid consent, then exactly the consented values. No token, no link."""
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

    serve(bind, consent["port"], consent["allow_hosts"], on_start=started, on_stop=stopped)


def status(paths, host, *, out, cgroup_applies, journal_is_persistent):
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
