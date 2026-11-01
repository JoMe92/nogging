"""Pure security decisions of `nogg dashboard`.

Everything here decides from values passed in: the bind policy, the token and
cookie rules, the Host and Origin checks and the response headers. The only
effects are the secret-file helpers at the bottom, which touch one named file.
Nothing here opens a socket, reads a request or starts a process.
"""
from __future__ import annotations

import hashlib, hmac, ipaddress, os, re, secrets, stat, threading, time
from collections import deque
from dataclasses import dataclass
from pathlib import Path

# The explicit bind allow-list of the spec. `is_private` and `is_global` are never
# used: their meaning changed across patch releases, and CGNAT is not `is_private`.
_LOOPBACK = tuple(ipaddress.ip_network(net) for net in ("127.0.0.0/8", "::1/128"))
_PRIVATE = tuple(ipaddress.ip_network(net) for net in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
    "100.64.0.0/10", "fc00::/7"))
_LINK_LOCAL_V6 = ipaddress.ip_network("fe80::/10")
_CGNAT = ipaddress.ip_network("100.64.0.0/10")
_WILDCARDS = (ipaddress.ip_address("0.0.0.0"), ipaddress.ip_address("::"))
_ZONE = re.compile(r"^[A-Za-z0-9._-]{1,15}$")

LIST_HINT = "run `nogg dashboard --list-binds` to list eligible addresses"


class BindRefused(ValueError):
    """The refused value is named in the message, with the way forward."""


@dataclass(frozen=True)
class Bind:
    """An accepted bind address: literal, in the allow-list and ready to use."""
    address: str
    zone: str | None
    loopback: bool

    @property
    def family_v6(self):
        return ":" in self.address

    @property
    def host(self):
        """The address as it appears in a URL or a Host header, without a zone."""
        return f"[{self.address}]" if self.family_v6 else self.address


def _in_any(addr, networks):
    return any(addr.version == net.version and addr in net for net in networks)


def check_bind(value):
    """Return a `Bind` for an allowed literal address; raise `BindRefused` otherwise."""
    text = value if isinstance(value, str) else str(value)
    literal, percent, zone = text.partition("%")
    try:
        addr = ipaddress.ip_address(literal)
    except ValueError:
        raise BindRefused(f"refusing bind address {text!r}: give a literal IP address, "
                          f"not a hostname; {LIST_HINT}") from None
    if addr in _WILDCARDS:
        raise BindRefused(f"refusing wildcard bind address {text!r}: it covers every interface, "
                          f"including future public ones; {LIST_HINT}")
    if addr.version == 6 and addr.ipv4_mapped is not None:
        raise BindRefused(f"refusing IPv4-mapped bind address {text!r}: give the IPv4 address "
                          f"itself; {LIST_HINT}")
    if _in_any(addr, (_LINK_LOCAL_V6,)):
        if not percent or not _ZONE.fullmatch(zone):
            raise BindRefused(f"refusing link-local bind address {text!r}: it needs a zone, "
                              f"as in fe80::1%eth0; {LIST_HINT}")
        return Bind(addr.compressed, zone, False)
    if percent:
        raise BindRefused(f"refusing bind address {text!r}: only a link-local IPv6 address "
                          f"takes a zone; {LIST_HINT}")
    if _in_any(addr, _LOOPBACK):
        return Bind(addr.compressed, None, True)
    if _in_any(addr, _PRIVATE):
        return Bind(addr.compressed, None, False)
    raise BindRefused(f"refusing bind address {text!r}: it is outside the private allow-list; "
                      f"{LIST_HINT}")


def plain_http_warning(bind):
    """What to tell the operator about a bind whose traffic may be read on the way.
    Loopback stays on the host. Tailscale encrypts its traffic, but carrier NAT uses
    the same range and no address alone tells them apart."""
    if bind.loopback:
        return None
    if ipaddress.ip_address(bind.address) in _CGNAT:
        return ("NOTE: this is plain HTTP, which is safe only if the address is Tailscale's. "
                "The same range is used for carrier NAT; see --list-binds.")
    return ("WARNING: this bind is plain HTTP, so anyone who can read this network can read "
            "the pages and replay the cookie. Prefer a Tailscale address.")


def peer_allowed(peer, loopback_only=False):
    """Whether a connecting peer lies in the bind allow-list. A zone a kernel adds to a
    link-local peer is dropped. A loopback bind has no token, so it trusts its peer to
    be on this host and takes no forwarded private address."""
    try:
        addr = ipaddress.ip_address(str(peer).partition("%")[0])
    except ValueError:
        return False
    if _in_any(addr, _LOOPBACK):
        return True
    return not loopback_only and (_in_any(addr, _PRIVATE) or _in_any(addr, (_LINK_LOCAL_V6,)))


def eligible_binds(ip_addr_json):
    """(address, warning or None) for `ip -j addr` output. A hint for the operator
    only: this result never feeds the bind decision."""
    rows = []
    for link in ip_addr_json if isinstance(ip_addr_json, list) else ():
        if not isinstance(link, dict):
            continue
        name = str(link.get("ifname") or "")
        for info in link.get("addr_info") or ():
            local = str((info or {}).get("local") or "")
            scoped = f"{local}%{name}" if local.lower().startswith(("fe8", "fe9", "fea", "feb")) else local
            try:
                bind = check_bind(scoped)
            except BindRefused:
                continue
            warning = None
            if ipaddress.ip_address(bind.address) in _CGNAT and not name.startswith("tailscale"):
                warning = f"on {name}, not a tailscale interface: this may be carrier NAT"
            rows.append((scoped, warning))
    return rows


# --- token and cookie -------------------------------------------------------------

COOKIE_MAX_AGE = 2592000            # 30 days
MIN_SECRET_LENGTH = 43              # 32 bytes in unpadded base64url
_SECRET_FORM = re.compile(r"^[A-Za-z0-9_-]+$")
_COOKIE_VALUE = re.compile(r"^([0-9]{1,12})\.([0-9a-f]{64})$")
_COOKIE_LABEL = b"nogg-dashboard-cookie\0"


def new_secret():
    return secrets.token_urlsafe(32)


def secret_acceptable(secret):
    """An empty or short secret would make every HMAC guessable. An unclean host
    stop can leave a zeroed file, so this is checked on every read."""
    return (isinstance(secret, str) and len(secret) >= MIN_SECRET_LENGTH
            and bool(_SECRET_FORM.fullmatch(secret)))


def _bytes(value):
    # compare_digest raises on non-ASCII str, and a header can hold anything.
    return value.encode("utf-8", "replace")


def token_matches(secret, supplied):
    """Constant-time comparison on bytes; a missing value never matches."""
    if not secret_acceptable(secret) or not isinstance(supplied, str):
        return False
    return hmac.compare_digest(_bytes(secret), _bytes(supplied))


def bearer_token(header):
    """The token of an `Authorization: Bearer <token>` value, or None."""
    scheme, _, token = (header or "").strip().partition(" ")
    return token.strip() or None if scheme.lower() == "bearer" else None


def cookie_name(port):
    return f"nogg-dash-{port}"


def _cookie_mac(secret, expiry):
    return hmac.new(_bytes(secret), _COOKIE_LABEL + str(expiry).encode(), hashlib.sha256).hexdigest()


def sign_cookie(secret, expiry):
    return f"{expiry}.{_cookie_mac(secret, expiry)}"


def cookie_state(secret, value, now):
    """"valid", "expired" for a genuine cookie past its date, or "bad". Only "bad" can be
    a guess: an expired cookie is a phone coming back, not an attack."""
    match = _COOKIE_VALUE.fullmatch(value) if isinstance(value, str) else None
    if match is None or not secret_acceptable(secret):
        return "bad"
    expiry = int(match.group(1))
    if not hmac.compare_digest(_cookie_mac(secret, expiry).encode(), match.group(2).encode()):
        return "bad"
    return "valid" if now < expiry else "expired"


def cookie_from_header(header, name):
    """The value of cookie `name` in a Cookie header, or None."""
    for part in (header or "").split(";"):
        key, sep, value = part.strip().partition("=")
        if sep and key == name:
            return value
    return None


def set_cookie_value(port, secret, now):
    expiry = int(now) + COOKIE_MAX_AGE
    return (f"{cookie_name(port)}={sign_cookie(secret, expiry)}; HttpOnly; SameSite=Strict; "
            f"Path=/; Max-Age={COOKIE_MAX_AGE}")


class FailureLimit:
    """Failed authentications within a sliding window, globally. With 256 bits this
    only reduces noise; it is no defence on which the token relies."""

    def __init__(self, limit=10, window=60.0, clock=time.monotonic):
        self.limit, self.window, self.clock = limit, window, clock
        self._failures = deque()
        self._lock = threading.Lock()

    def _trim(self, now):
        while self._failures and now - self._failures[0] >= self.window:
            self._failures.popleft()

    def blocked(self):
        with self._lock:
            self._trim(self.clock())
            return len(self._failures) >= self.limit

    def record(self):
        with self._lock:
            now = self.clock()
            self._trim(now)
            if len(self._failures) < self.limit:
                self._failures.append(now)

    def retry_after(self):
        """Whole seconds until the oldest failure leaves the window, at least 1."""
        with self._lock:
            now = self.clock()
            self._trim(now)
            if not self._failures:
                return 1
            return max(1, int(self._failures[0] + self.window - now + 0.999))


# --- Host, Origin and the rest of a request ----------------------------------------

_ALLOW_HOST_FORM = re.compile(r"^(?:\[[0-9a-f:.]+\]|[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?)(?::[0-9]{1,5})?$")
BEAD_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


def check_allow_host(value):
    """Normalise one `--allow-host` literal. A wildcard, a scheme or a path is refused."""
    text = str(value).strip().lower()
    if not _ALLOW_HOST_FORM.fullmatch(text):
        raise BindRefused(f"refusing --allow-host {value!r}: give a literal host or host:port")
    return text


def allowed_hosts(bind, port, extra=()):
    """The exact Host values this server answers, all in lower case."""
    names = [bind.host] + (["localhost"] if bind.loopback else [])
    hosts = {f"{name}:{port}" for name in names}
    if port == 80:
        hosts.update(names)
    hosts.update(check_allow_host(value) for value in extra)
    return frozenset(host.lower() for host in hosts)


def host_status(values, hosts):
    """HTTP status for the Host headers of a request; None when allowed."""
    if len(values) != 1 or not values[0].strip():
        return 400
    return None if values[0].strip().lower() in hosts else 421


def origin_allowed(origins, fetch_sites, hosts):
    """Every present Origin equals our own origin, and every Sec-Fetch-Site is
    same-origin or none. An absent header says nothing, as for a plain client."""
    own = {f"http://{host}" for host in hosts}
    return (all(value.strip().lower() in own for value in origins)
            and all(value.strip().lower() in ("same-origin", "none") for value in fetch_sites))


def accepts_gzip(header):
    """Whether Accept-Encoding allows gzip; an explicit q=0 refuses it."""
    for part in (header or "").lower().split(","):
        name, _, params = part.strip().partition(";")
        if name.strip() == "gzip":
            weight = params.replace(" ", "")
            return not re.fullmatch(r"q=0(?:\.0{0,3})?", weight)
    return False


CONTENT_SECURITY_POLICY = (
    "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; "
    "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; "
    "require-trusted-types-for 'script'")


def security_headers(api):
    """The headers every response carries; API and auth responses are also uncacheable."""
    headers = [("Content-Security-Policy", CONTENT_SECURITY_POLICY),
               ("X-Frame-Options", "DENY"),
               ("Referrer-Policy", "no-referrer"),
               ("X-Content-Type-Options", "nosniff"),
               ("Cross-Origin-Resource-Policy", "same-origin")]
    headers.append(("Cache-Control", "no-store" if api else "no-cache"))
    return headers


# --- the secret file ---------------------------------------------------------------

class SecretRefused(RuntimeError):
    """A secret file or directory that must not be used; the message names the fix."""


def mode_problem(path):
    """Why the secret at `path` is too open, or None. `doctor` shares this check."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        return f"{path} is not a regular file"
    if stat.S_IMODE(info.st_mode) & 0o077:
        return f"{path} has mode {stat.S_IMODE(info.st_mode):04o}, wider than the required 0600"
    return None


def _check_directory(directory):
    info = os.lstat(directory)
    if not stat.S_ISDIR(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
        raise SecretRefused(f"{directory} must be a directory with mode 0700; "
                            f"fix it with `chmod 700 {directory}`")


def read_secret(path):
    """The stored secret, or None when no file exists. A file that is too open, not
    ours or malformed is refused and never returned."""
    path = Path(path)
    remedy = f"fix it with `chmod 600 {path}`, or replace it with `nogg dashboard --rotate-token`"
    problem = mode_problem(path)
    if problem:
        raise SecretRefused(f"{problem}; {remedy}")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None
    with os.fdopen(fd, "rb") as handle:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
            raise SecretRefused(f"{path} changed while it was read; the required mode is 0600")
        raw = handle.read(1024)
    if info.st_uid != os.geteuid():
        raise SecretRefused(f"{path} belongs to another user; the required mode is 0600 and "
                            "the owner is the operator")
    text = raw.decode("ascii", "replace").strip()
    if not secret_acceptable(text):
        raise SecretRefused(f"{path} does not hold a usable secret; replace it with "
                            "`nogg dashboard --rotate-token`")
    return text


def _write_new(path, secret):
    """Create `path` with O_EXCL, already at mode 0600, and reach the disk."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(secret + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def _sync_directory(directory):
    """A rename or a new name reaches the disk only with its directory, and this host
    can lose power: a stale secret after a rotation would bring old cookies back. The
    change has already happened here, so a filesystem that refuses this is no failure."""
    try:
        fd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def _prepare_directory(path):
    directory = Path(path).parent
    directory.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.mkdir(directory, 0o700)
    except FileExistsError:
        pass
    _check_directory(directory)


def ensure_secret(path):
    """Read the secret, creating it on the first non-loopback start."""
    path = Path(path)
    _prepare_directory(path)
    found = read_secret(path)
    if found is not None:
        return found
    try:
        _write_new(path, new_secret())
        _sync_directory(path.parent)
    except FileExistsError:
        pass                       # another start won the O_EXCL race; read its secret
    return read_secret(path)


def rotate_secret(path):
    """Replace the secret atomically. A leftover temporary file from a crash is removed
    first, so a retry works. Mode problems on the old file do not block a rotation:
    replacing an exposed secret is exactly what that file needs."""
    path = Path(path)
    _prepare_directory(path)
    temporary = path.with_name(path.name + ".new")
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    _write_new(temporary, new_secret())
    os.replace(temporary, path)
    _sync_directory(path.parent)


class SecretWatch:
    """The current secret for a running server. `--rotate-token` from another terminal
    must end every old session at once, so the file identity is checked on each use.
    A change is re-read; a file that is gone or refused closes the door (None)."""

    def __init__(self, path, secret):
        self.path = Path(path)
        self._secret = secret
        self._lock = threading.Lock()
        self._identity = self._stat()

    def _stat(self):
        try:
            info = os.lstat(self.path)
        except OSError:
            return None
        return (info.st_ino, info.st_mtime_ns, info.st_size, info.st_mode)

    def current(self):
        identity = self._stat()
        with self._lock:
            if identity != self._identity:
                self._identity = identity
                try:
                    self._secret = read_secret(self.path) if identity else None
                except (OSError, SecretRefused):
                    self._secret = None
            return self._secret
