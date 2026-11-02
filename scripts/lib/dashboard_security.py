"""Pure security decisions of `nogg dashboard`.

Everything here decides from values passed in: the bind policy, the operator-terminal
test, the token and cookie rules, the Host and Origin checks and the response headers. The only
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


# --- the operator-terminal test ---------------------------------------------------

_SESSION_SCOPE = re.compile(r"^session-[A-Za-z0-9_.-]+\.scope$")


def systemd_cgroup(text):
    """The systemd cgroup path in `/proc/<pid>/cgroup` text: the `name=systemd` line of a
    v1 or hybrid host, else the unified `0::` line; None when neither is there."""
    unified = None
    for line in (text or "").splitlines():
        parts = line.split(":", 2)
        if len(parts) != 3:
            continue
        if parts[1] == "name=systemd":
            return parts[2]
        if parts[0] == "0" and parts[1] == "":
            unified = parts[2]
    return unified


def login_scope(path):
    """Whether a cgroup path ends in a logind session scope (`session-<id>.scope`)."""
    return bool(path) and _SESSION_SCOPE.match(path.rstrip("/").rsplit("/", 1)[-1]) is not None


def terminal_refusal(*, session_problem, stdin_tty, servers, ancestry, cgroup):
    """Which condition of the operator-terminal test fails, as a sentence, or None when
    the caller is a person at a login terminal. The facts are passed in:

    - `session_problem`: why the caller counts as a session (a proven one, or a session
      name that ancestry does not prove), or None;
    - `stdin_tty`: whether stdin is a terminal; stdout is never tested;
    - `servers`: a call giving `(label, pid, start)` for each shared session server that
      runs, or a str saying why one cannot be identified (which fails closed);
    - `ancestry`: a call giving the `(pid, start)` pairs of the caller's ancestors;
    - `cgroup`: a call giving the caller's cgroup text, or None where the host has no
      cgroups or no systemd, which skips that condition.

    The calls run only once the cheaper conditions hold, in this order."""
    if session_problem:
        return session_problem
    if not stdin_tty:
        return "stdin is not a terminal, as under nohup, systemd-run, setsid or an agent's tool call"
    running = servers()
    if isinstance(running, str):
        return f"it cannot tell whether it runs under the shared Nogging session server: {running}"
    parents = set(ancestry())
    for label, pid, start in running:
        if any(seen == pid and (start is None or born == start) for seen, born in parents):
            return f"it runs under the shared Nogging session server ({label}, pid {pid})"
    text = cgroup()
    if text is not None:
        path = systemd_cgroup(text)
        if not login_scope(path):
            return (f"its cgroup {path or '(none)'} is not a logind session scope (session-<id>.scope), "
                    "as under `systemd-run --user --pty`, a service, or a tmux built with systemd support, "
                    "which moves each pane into its own scope")
    return None


def terminal_refusal_message(address, reason):
    """The refusal of a non-loopback `--bind` that fails the operator-terminal test."""
    return (f"refusing --bind {address} outside an operator terminal: a network bind runs in the "
            "foreground on a login terminal, or as the consented service (`nogg dashboard service "
            f"enable` on a terminal); here {reason}. From another host, run it with `ssh -t`")


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


def new_cookie(secret, now):
    """A fresh signed cookie value, valid for COOKIE_MAX_AGE from `now`."""
    return sign_cookie(secret, int(now) + COOKIE_MAX_AGE)


def cookie_header(port, value):
    return f"{cookie_name(port)}={value}; HttpOnly; SameSite=Strict; Path=/; Max-Age={COOKIE_MAX_AGE}"


def set_cookie_value(port, secret, now):
    return cookie_header(port, new_cookie(secret, now))


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


# --- one-time pairing links ----------------------------------------------------------

PAIRING_TTL = 300.0                 # five minutes
PAIRING_OPEN_MAX = 3
TOMBSTONE_TTL = 3600.0              # a late tap is answered as used or expired for an hour
TOMBSTONE_MAX = 32
_PAIRING_LABEL = b"nogg-dashboard-pairing\0"


def new_pairing_code():
    """128 bits as 32 lowercase hex digits: nothing a chat's Markdown can reformat."""
    return secrets.token_hex(16)


def _digest(value):
    return hashlib.sha256(_bytes(value)).hexdigest()


def pairing_id(code):
    """The first 8 hex digits of the code's hash: all of it the audit trail ever names."""
    return _digest(code)[:8]


def pairing_code(header):
    """The code of an `Authorization: Pairing <code>` value, or None."""
    scheme, _, code = (header or "").strip().partition(" ")
    return code.strip() or None if scheme.lower() == "pairing" else None


def _secret_binding(secret):
    return hashlib.sha256(_PAIRING_LABEL + _bytes(secret)).hexdigest()


@dataclass(frozen=True)
class Minted:
    code: str
    id: str
    ttl: float
    ended: int               # open links this mint ended to stay within PAIRING_OPEN_MAX


@dataclass(frozen=True)
class Redemption:
    """What a redemption found. `outcome` is one of:

    - `redeemed`: the code was open and is now used; issue the cookie offered;
    - `again`: used, and the request carries the very cookie this redemption issued;
    - `used_elsewhere`: used, and the request carries another valid cookie;
    - `used`: used, and the request carries no valid cookie;
    - `expired`: past its time, or ended by a rotation or a newer mint;
    - `unknown`: never minted here (a guess, or a code from before a restart).

    `same_peer` says, for both used answers, whether the peer is the redeeming one, and
    `first_replay` whether this is the first replay of the code (recorded once)."""
    outcome: str
    id: str | None = None
    same_peer: bool = False
    first_replay: bool = False


@dataclass
class _Pairing:
    expires: float
    binding: str
    order: int
    state: str = "open"              # open, used or expired
    done_at: float | None = None
    cookie: str | None = None        # sha256 of the cookie the redemption issued
    peer: str | None = None
    replayed: bool = False


class PairingStore:
    """Open pairing codes of one running server, held in memory as SHA-256 hashes only.
    A code is good for PAIRING_TTL seconds and one redemption, under the secret current
    when it was minted. Every change happens under one lock, so of two concurrent
    redemptions exactly one is `redeemed`. No I/O: the clock is injected, and the
    caller writes the audit trail."""

    def __init__(self, clock=time.monotonic, ttl=PAIRING_TTL, open_max=PAIRING_OPEN_MAX,
                 tombstone_ttl=TOMBSTONE_TTL, tombstone_max=TOMBSTONE_MAX):
        self.clock, self.ttl, self.open_max = clock, ttl, open_max
        self.tombstone_ttl, self.tombstone_max = tombstone_ttl, tombstone_max
        self._entries, self._order = {}, 0
        self._lock = threading.Lock()

    def _end(self, entry, at):
        entry.state, entry.done_at = "expired", at

    def _prune(self, now, binding=None):
        """Expire what has run out or no longer matches the secret, then drop tombstones
        older than an hour and keep at most `tombstone_max`."""
        for entry in self._entries.values():
            if entry.state == "open" and now >= entry.expires:
                self._end(entry, entry.expires)
            elif entry.state == "open" and binding is not None and entry.binding != binding:
                self._end(entry, now)
        dead = sorted((entry.done_at, entry.order, key) for key, entry in self._entries.items()
                      if entry.state != "open")
        for done_at, _, key in dead:
            if now - done_at >= self.tombstone_ttl:
                del self._entries[key]
        dead = [key for _, _, key in dead if key in self._entries]
        for key in dead[:max(0, len(dead) - self.tombstone_max)]:
            del self._entries[key]

    def mint(self, secret, code=None):
        """A new open code bound to `secret`; the oldest open code ends when the limit is
        reached. `code` comes from `new_pairing_code()` unless the caller made one first, as
        a server does to record the mint before the code is valid."""
        if not secret_acceptable(secret):
            raise ValueError("no usable secret: a pairing code needs one")
        code = code or new_pairing_code()
        binding = _secret_binding(secret)
        with self._lock:
            now = self.clock()
            self._prune(now, binding)
            opened = sorted((entry.order, entry) for entry in self._entries.values() if entry.state == "open")
            ended = 0
            for _, entry in opened[:max(0, len(opened) - self.open_max + 1)]:
                self._end(entry, now)
                ended += 1
            self._order += 1
            self._entries[_digest(code)] = _Pairing(now + self.ttl, binding, self._order)
            self._prune(now)
        return Minted(code, pairing_id(code), self.ttl, ended)

    def redeem(self, code, secret, *, issue, presented, peer):
        """Use `code` once. `issue` is the cookie value this request would set, signed
        with `secret`; `presented` is the request's own cookie when it is valid, else
        None; `peer` is the client address."""
        key, binding = _digest(code), _secret_binding(secret)
        with self._lock:
            now = self.clock()
            self._prune(now, binding)
            entry = self._entries.get(key)
            if entry is None:
                return Redemption("unknown")
            ident = key[:8]
            if entry.state == "expired":
                return Redemption("expired", ident)
            if entry.state == "open":
                entry.state, entry.done_at = "used", now
                entry.cookie, entry.peer = _digest(issue), peer
                return Redemption("redeemed", ident)
            same = peer == entry.peer
            if presented is not None and hmac.compare_digest(_digest(presented), entry.cookie):
                return Redemption("again", ident, same)
            first, entry.replayed = not entry.replayed, True
            return Redemption("used_elsewhere" if presented is not None else "used", ident, same, first)

    def status(self, secret):
        """`(open links, seconds until the earliest one expires or None)`; codes minted
        under another secret count as ended. Without a usable secret none is open."""
        if not secret_acceptable(secret):
            return 0, None
        with self._lock:
            now = self.clock()
            self._prune(now, _secret_binding(secret))
            remaining = [entry.expires - now for entry in self._entries.values() if entry.state == "open"]
        return len(remaining), (min(remaining) if remaining else None)


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
