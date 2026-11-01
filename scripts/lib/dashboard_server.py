"""The HTTP server of `nogg dashboard`: routes, static map, limits and lifecycle.

GET and HEAD only, on HTTP/1.0 with no keep-alive. Assets load into a fixed map at
start, so no request can name a path, and nothing here logs a request: the only
output is the address and, on a terminal, the link. Every decision about what is
allowed lives in `dashboard_security`.
"""
from __future__ import annotations

import errno, gzip, json, re, shutil, signal, socket, socketserver, subprocess, sys, threading, time
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path

import dashboard_cache as cache
import dashboard_graph as graph
import dashboard_model as model
import dashboard_security as sec

DEFAULT_PORT = 8742
MAX_THREADS = 16
MAX_REQUEST_LINE = 8 * 1024
MAX_HEADERS = 16 * 1024
SOCKET_TIMEOUT = 5.0
READ_DEADLINE = 10.0
DRAIN_SECONDS = 1.0
DRAIN_BYTES = 256 * 1024
_HEAD_END = re.compile(rb"\n\r?\n")

CONTENT_TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
                 ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml",
                 ".png": "image/png", ".ico": "image/x-icon", ".woff2": "font/woff2",
                 ".txt": "text/plain; charset=utf-8"}
COMPRESSIBLE = {".html", ".js", ".css", ".svg", ".txt"}
REASONS = {400: "bad_request", 401: "unauthorized", 403: "forbidden", 404: "not_found",
           405: "method_not_allowed", 414: "uri_too_long", 421: "misdirected_request",
           429: "too_many_requests", 431: "headers_too_large", 500: "internal_error",
           501: "not_built", 503: "busy"}


def iso(timestamp):
    moment = datetime.fromtimestamp(timestamp, timezone.utc)
    return moment.isoformat(timespec="seconds").replace("+00:00", "Z")


@dataclass(frozen=True)
class Response:
    status: int
    body: bytes
    content_type: str = "application/json"
    gzipped: bytes | None = None
    api: bool = True
    headers: tuple = ()


@dataclass(frozen=True)
class Request:
    path: str
    query: str
    match: re.Match | None
    authorization: str | None
    cookie: str | None


def load_assets(directory):
    """The fixed map of URL path to Response. It is built once at start, and a request
    only ever looks a key up. A symbolic link or an unknown file type is left out."""
    directory, assets = Path(directory), {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink() or not path.is_file() or path.suffix not in CONTENT_TYPES:
            continue
        relative = path.relative_to(directory).as_posix()
        body = path.read_bytes()
        packed = gzip.compress(body, mtime=0) if path.suffix in COMPRESSIBLE else None
        assets["/" if relative == "index.html" else f"/assets/{relative}"] = Response(
            200, body, CONTENT_TYPES[path.suffix], packed, api=False)
    if "/" not in assets:
        raise RuntimeError(f"dashboard shell is missing: {directory / 'index.html'}")
    return assets


# --- routes -----------------------------------------------------------------------

def api_response(server, name, data, sources=None, headers=()):
    """The envelope every API response uses."""
    doc = {"schema": f"nogg.dashboard.{name}/v1", "as_of": iso(server.wall_clock()),
           "sources": sources or {}, "data": data}
    return Response(200, json.dumps(doc, sort_keys=True).encode(), headers=tuple(headers))


def api_error(server, status, headers=()):
    """A refusal: the envelope with a fixed reason, and nothing from the request."""
    doc = {"schema": "nogg.dashboard.error/v1", "as_of": iso(server.wall_clock()),
           "sources": {}, "data": {"error": REASONS[status]}}
    return Response(status, json.dumps(doc, sort_keys=True).encode(), headers=tuple(headers))


def too_many(server):
    return api_error(server, 429, [("Retry-After", str(server.failures.retry_after()))])


def refuse_attempt(server):
    """A failed authentication: 401, then 429 once the limit is reached. The limit only
    ever applies after a mismatch, so no flood can refuse a correct token or session."""
    if server.failures.blocked():
        return too_many(server)
    server.failures.record()
    return api_error(server, 401)


def check_session(server, request):
    """None when the request may go on, otherwise the refusal. A request with no cookie
    or a genuine expired one is not an attempt at guessing, so it is a plain 401."""
    if not server.token_required:
        return None
    cookie = sec.cookie_from_header(request.cookie, sec.cookie_name(server.port))
    if cookie is None:
        return api_error(server, 401)
    state = sec.cookie_state(server.secret.current(), cookie, server.wall_clock())
    if state == "valid":
        return None
    return api_error(server, 401) if state == "expired" else refuse_attempt(server)


def route_auth(server, request):
    """Trade the token for a cookie, or report whether the session is still good."""
    if not server.token_required:
        return api_response(server, "auth", {})
    token = sec.bearer_token(request.authorization)
    if token is None:
        return check_session(server, request) or api_response(server, "auth", {})
    secret = server.secret.current()
    if not sec.token_matches(secret, token):
        return refuse_attempt(server)
    cookie = sec.set_cookie_value(server.port, secret, server.wall_clock())
    return api_response(server, "auth", {}, headers=[("Set-Cookie", cookie)])


def render_api(server, name, sources, build, memo=None):
    """A cached API response built from the named sources. It is built and compressed
    once per change of those sources, so a request only looks it up. `memo` tells apart
    the responses of a route that takes parameters. Every API request is demand: it keeps
    the refresher awake."""
    server.refresher.touch()

    def make(snapshots, statuses):
        as_of = max((item["as_of"] for item in statuses.values() if item["as_of"]), default=None)
        doc = {"schema": f"nogg.dashboard.{name}/v1", "as_of": as_of or iso(server.wall_clock()),
               "sources": statuses, "data": build(snapshots, statuses)}
        body = json.dumps(doc, sort_keys=True).encode()
        return Response(200, body, gzipped=gzip.compress(body, mtime=0))
    return server.refresher.render(memo or name, sources, make)


def route_freshness(server, request):
    return render_api(server, "freshness", list(server.refresher.cells), lambda snapshots, statuses: statuses)


def route_beads(server, request):
    return render_api(server, "beads", ["beads"],
                      lambda snapshots, statuses: model.bead_list(snapshots.get("beads") or {}))


def route_changes(server, request):
    return render_api(server, "changes", ["beads"],
                      lambda snapshots, statuses: model.change_list(snapshots.get("beads") or {}))


def route_bead_detail(server, request):
    return api_error(server, 501)


def route_summary(server, request):
    return api_error(server, 501)


def route_graph(server, request):
    """One change, the neighbourhood of one Bead or the ready frontier as a flow. A reload
    that changes nothing rebuilds the envelope, and the layout comes from the graph cache."""
    try:
        scope, closed, depth = graph.parse_request(request.query)
    except ValueError:
        return api_error(server, 400)

    def build(snapshots, statuses):
        generation = statuses.get("beads", {}).get("generation")
        return server.graph_cache.view(generation, (scope, closed, depth),
                                       lambda: graph.graph_view(snapshots.get("beads") or {}, scope, closed, depth))
    return render_api(server, "graph", ["beads"], build, memo=f"graph?{scope}&{closed}&{depth}")


ROUTES = ((re.compile(r"/api/v1/auth"), route_auth),
          (re.compile(r"/api/v1/freshness"), route_freshness),
          (re.compile(r"/api/v1/beads"), route_beads),
          (re.compile(r"/api/v1/changes"), route_changes),
          (re.compile(r"/api/v1/beads/(?P<id>[^/]+)"), route_bead_detail),
          (re.compile(r"/api/v1/summary"), route_summary),
          (re.compile(r"/api/v1/graph"), route_graph))


def find_route(path):
    """(route, match), or (None, None). A Bead ID that fails the strict form is no route."""
    for pattern, route in ROUTES:
        match = pattern.fullmatch(path)
        if match is None:
            continue
        if "id" in pattern.groupindex and not sec.BEAD_ID.fullmatch(match.group("id")):
            return None, None
        return route, match
    return None, None


# --- the request handler ----------------------------------------------------------

class DashboardHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    default_request_version = "HTTP/1.0"
    server_version = "nogg-dashboard"
    sys_version = ""
    timeout = SOCKET_TIMEOUT
    drain = False
    trailing = False

    def handle(self):
        """One request per connection. The head is read here, not through `rfile`: the
        socket timeout alone does not stop a client that sends a byte every few seconds."""
        self.close_connection = True
        self.request_version = "HTTP/1.0"
        self.requestline, self.command = "", None
        try:
            head = self._read_head()
            if head is None:
                return
            line_end = head.index(b"\n") + 1
            self.raw_requestline, self.rfile = head[:line_end], BytesIO(head[line_end:])
            if self.parse_request():
                self._write(self._answer())
        except OSError:
            pass                   # a reset, a timeout: the client has gone

    def _answer(self):
        """A failing route is a fixed 500, never a traceback on the wire."""
        try:
            return self._dispatch()
        except Exception:
            self.server.handle_error(self.connection, self.client_address)
            return api_error(self.server, 500)

    def _read_head(self):
        clock, deadline = self.server.clock, self.server.clock() + self.server.read_deadline
        buffer = bytearray()
        while True:
            remaining = deadline - clock()
            if remaining <= 0:
                return None
            self.connection.settimeout(min(SOCKET_TIMEOUT, remaining))
            chunk = self.connection.recv(4096)
            if not chunk:
                return None
            buffer += chunk
            line_end = buffer.find(b"\n")
            if line_end > MAX_REQUEST_LINE or (line_end < 0 and len(buffer) > MAX_REQUEST_LINE):
                return self._refuse_oversize(414)
            if line_end < 0:
                continue
            end = _HEAD_END.search(buffer, line_end)
            if (end.end() if end else len(buffer)) - line_end - 1 > MAX_HEADERS:
                return self._refuse_oversize(431)
            if end:
                self.trailing = end.end() < len(buffer)
                return bytes(buffer[:end.end()])

    def _refuse_oversize(self, status):
        self.drain = True
        self._write(api_error(self.server, status))
        return None

    def _dispatch(self):
        server = self.server
        if self.command not in ("GET", "HEAD"):
            self.drain = True
            return api_error(server, 405, [("Allow", "GET, HEAD")])
        status = sec.host_status(self.headers.get_all("Host") or [], server.hosts)
        if status:
            return api_error(server, status)
        if self.headers.defects or self.headers.get_payload():
            return api_error(server, 400)    # parsing stopped early: later headers went unseen
        if not sec.origin_allowed(self.headers.get_all("Origin") or [],
                                  self.headers.get_all("Sec-Fetch-Site") or [], server.hosts):
            return api_error(server, 403)
        if self._has_body():
            self.drain = True
            return api_error(server, 400)
        path, _, query = self.path.partition("?")
        asset = server.assets.get(path)
        if asset is not None:
            return asset
        route, match = find_route(path)
        if route is None:
            return api_error(server, 404)
        request = Request(path, query, match, self.headers.get("Authorization"), self.headers.get("Cookie"))
        refused = None if route is route_auth else check_session(server, request)
        return refused or route(server, request)

    def _has_body(self):
        lengths = self.headers.get_all("Content-Length") or []
        return self.trailing or "Transfer-Encoding" in self.headers or any(
            value.strip() != "0" for value in lengths)

    def _write(self, response):
        self.connection.settimeout(SOCKET_TIMEOUT)
        packed = response.gzipped is not None and sec.accepts_gzip(
            self.headers.get("Accept-Encoding") if getattr(self, "headers", None) else None)
        body = response.gzipped if packed else response.body
        self.send_response(response.status)
        self.send_header("Content-Type", response.content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        if response.gzipped is not None:
            self.send_header("Vary", "Accept-Encoding")
        if packed:
            self.send_header("Content-Encoding", "gzip")
        for name, value in (*sec.security_headers(response.api), *response.headers):
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_error(self, code, message=None, explain=None):
        """The standard library's error page echoes the request line."""
        self.drain = True
        self._write(api_error(self.server, code if code in REASONS else 400))

    def version_string(self):
        return self.server_version

    def log_message(self, format, *args):
        """Nothing about a request is logged: a line could carry a token or a path."""

    def finish(self):
        super().finish()
        if self.drain:
            self._drain()

    def _drain(self):
        """Closing with unread bytes resets the connection and can lose the refusal, so
        read what a refused client still sends, for a bounded time and amount."""
        try:
            self.connection.shutdown(socket.SHUT_WR)
            end, seen = time.monotonic() + DRAIN_SECONDS, 0
            while seen < DRAIN_BYTES and (left := end - time.monotonic()) > 0:
                self.connection.settimeout(left)
                chunk = self.connection.recv(16384)
                if not chunk:
                    return
                seen += len(chunk)
        except OSError:
            pass


# --- the server -------------------------------------------------------------------

def busy_bytes():
    """The canned answer of a full server, ready before any request exists. It goes out
    from the accept loop, which must never block on one client."""
    body = b'{"error":"busy"}'
    lines = ["HTTP/1.0 503 Service Unavailable", "Content-Type: application/json",
             f"Content-Length: {len(body)}", "Connection: close",
             *(f"{name}: {value}" for name, value in sec.security_headers(True))]
    return "\r\n".join(lines).encode() + b"\r\n\r\n" + body


class DashboardServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, bind, port, *, assets, readers, secret=None, allow_hosts=(),
                 clock=time.monotonic, wall_clock=time.time, read_deadline=READ_DEADLINE,
                 gates=None, refresher=None):
        self.bind_address, self.assets, self.readers = bind, assets, readers
        # The refresher is built here and started by `serve`: a request only reads it.
        self.refresher = refresher or cache.Refresher(readers, gates, clock=clock, wall_clock=wall_clock)
        self.graph_cache = graph.GraphCache()
        self.secret, self.clock, self.wall_clock = secret, clock, wall_clock
        self.read_deadline = read_deadline
        self.token_required = not bind.loopback
        allow_hosts = tuple(sec.check_allow_host(value) for value in allow_hosts)
        self.failures = sec.FailureLimit(clock=clock)
        self._active, self._idle, self._busy = 0, threading.Condition(), busy_bytes()
        self.address_family = socket.AF_INET6 if bind.family_v6 else socket.AF_INET
        super().__init__(self._socket_address(bind, port), DashboardHandler, bind_and_activate=False)
        try:
            self.server_bind()
            self.server_activate()
        except BaseException:
            self.server_close()
            raise
        self.hosts = sec.allowed_hosts(bind, self.port, allow_hosts)

    @staticmethod
    def _socket_address(bind, port):
        if bind.zone is None:
            return (bind.address, port)
        # A numeric lookup only: it turns the zone into a scope id and sends no query.
        return socket.getaddrinfo(f"{bind.address}%{bind.zone}", port, socket.AF_INET6,
                                  socket.SOCK_STREAM, 0, socket.AI_NUMERICHOST)[0][4]

    def server_bind(self):
        if self.address_family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        socketserver.TCPServer.server_bind(self)   # HTTPServer's would do a reverse lookup
        self.server_name, self.server_port = self.bind_address.address, self.socket.getsockname()[1]

    @property
    def port(self):
        return self.server_port

    def verify_request(self, request, client_address):
        """Runs in the accept loop, before a thread starts. It catches a DNAT forward that
        keeps a public source, and a private one on a loopback bind, which has no token.
        SNAT and proxies look local here, so they are for Host and the token."""
        return sec.peer_allowed(client_address[0], loopback_only=self.bind_address.loopback)

    def process_request(self, request, client_address):
        with self._idle:
            full = self._active >= MAX_THREADS
            if not full:
                self._active += 1
        if full:
            return self._refuse_busy(request)
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._free_slot()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._free_slot()

    def _free_slot(self):
        with self._idle:
            self._active -= 1
            self._idle.notify_all()

    def _refuse_busy(self, request):
        try:
            request.setblocking(False)
            try:
                request.recv(MAX_REQUEST_LINE + MAX_HEADERS)
            except BlockingIOError:
                pass
            request.send(self._busy)
        except OSError:
            pass
        self.shutdown_request(request)

    def wait_idle(self, timeout):
        """True once no request thread runs; for a stop and for tests."""
        with self._idle:
            return self._idle.wait_for(lambda: self._active == 0, timeout)

    def handle_error(self, request, client_address):
        """Only the exception class: a traceback could quote a request value."""
        print(f"nogg dashboard: request failed: {sys.exc_info()[0].__name__}", file=sys.stderr, flush=True)


def link(bind, port, secret):
    host = bind.host if bind.zone is None else f"[{bind.address}%25{bind.zone}]"
    return f"http://{host}:{port}/#token={secret}"


def announce(bind, port, secret, stream=None, which=shutil.which, run=subprocess.run):
    """Print the address and, on a terminal only, the link. Session logs and files must
    not capture the token, and a QR tool gets it on stdin, never on its command line."""
    stream = stream if stream is not None else sys.stdout
    print(f"Nogging dashboard on http://{bind.host}:{port}/ (read-only; Ctrl-C stops it)", file=stream, flush=True)
    if bind.loopback:
        return
    warning = sec.plain_http_warning(bind)
    if warning:
        print(warning, file=stream, flush=True)
    if not stream.isatty():
        print("The access link is not printed because output is not a terminal; "
              "start `nogg dashboard` on a terminal to print it.", file=stream, flush=True)
        return
    address = link(bind, port, secret)
    print(f"Open once on each device: {address}", file=stream, flush=True)
    if which("qrencode"):
        try:
            run(["qrencode", "-t", "ANSIUTF8"], input=address, text=True, timeout=5, check=False)
        except (OSError, subprocess.SubprocessError):
            pass


def serve(bind, port, readers, *, static_dir, secret_path, allow_hosts=(), stop=None, stream=None, gates=None):
    """Run in the foreground until SIGINT or SIGTERM, or until `stop` is set."""
    assets = load_assets(static_dir)
    secret = sec.ensure_secret(secret_path) if not bind.loopback else None
    watch = sec.SecretWatch(secret_path, secret) if secret else None
    try:
        server = DashboardServer(bind, port, assets=assets, readers=readers, secret=watch, allow_hosts=allow_hosts,
                                 gates=gates)
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            raise RuntimeError(f"port {port} is already in use on {bind.address}; "
                               "choose another one with --port <n>") from None
        if exc.errno == errno.EADDRNOTAVAIL:
            raise RuntimeError(f"{bind.address} is not assigned to this host; {sec.LIST_HINT}") from None
        raise
    stop = stop if stop is not None else threading.Event()
    if threading.current_thread() is threading.main_thread():
        for number in (signal.SIGINT, signal.SIGTERM):
            signal.signal(number, lambda *_: stop.set())
    worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.2}, daemon=True)
    worker.start()
    server.refresher.start()           # the socket is open: the first load never delays it
    try:
        announce(bind, server.port, secret, stream)
        stop.wait()
    finally:
        server.refresher.stop()
        server.shutdown()
        server.server_close()
