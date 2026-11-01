#!/usr/bin/env python3
"""Medium tests of the dashboard server: a real server on 127.0.0.1, port 0.

A network bind cannot be assumed on a test host, so these build a `Bind` that is not
loopback but listens on 127.0.0.1. The clock is injected, nothing sleeps, and every
wait is on an event with a bounded timeout.
"""
from __future__ import annotations

import contextlib, gzip, io, json, select, socket, subprocess, sys, tempfile, threading, unittest
from pathlib import Path
from unittest import mock
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_security as sec
import dashboard_server as ds

LOOPBACK = sec.Bind("127.0.0.1", None, True)
NETWORK = sec.Bind("127.0.0.1", None, False)     # token rules of a network bind


class Clock:
    def __init__(self, now=1000.0):
        self.now = now

    def __call__(self):
        return self.now


def assets_dir(root):
    root = Path(root)
    (root / "images").mkdir(parents=True)
    (root / "index.html").write_text("<!doctype html><title>shell</title>" + " " * 500)
    (root / "app.js").write_text("// app\n" * 50)
    (root / "images" / "logo.png").write_bytes(b"\x89PNG")
    (root / "notes.bin").write_bytes(b"not served")
    return root


class Harness(unittest.TestCase):
    """Starts one server per test; `call` speaks raw HTTP so nothing is normalised."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.assets = ds.load_assets(assets_dir(self.root / "static"))
        self.secret_path = self.root / "state" / "dashboard" / "secret"
        self.clock, self.wall = Clock(), Clock(10_000.0)

    def start(self, bind=LOOPBACK, server_class=ds.DashboardServer, **options):
        watch = None
        if not bind.loopback:
            self.token = sec.ensure_secret(self.secret_path)
            watch = sec.SecretWatch(self.secret_path, self.token)
        self.server = server_class(bind, 0, assets=self.assets, readers={}, secret=watch,
                                   clock=self.clock, wall_clock=self.wall, **options)
        thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.host = f"127.0.0.1:{self.server.port}"
        return self.server

    def connect(self):
        return socket.create_connection(("127.0.0.1", self.server.port), timeout=5)

    def send(self, raw):
        with self.connect() as sock:
            sock.sendall(raw)
            return self.read(sock)

    @staticmethod
    def read(sock):
        data = b""
        try:
            while chunk := sock.recv(65536):
                data += chunk
        except ConnectionResetError:
            pass
        return data

    def call(self, path, method="GET", host=None, headers=()):
        lines = [f"{method} {path} HTTP/1.1", f"Host: {host or self.host}", *headers, "", ""]
        return parse(self.send("\r\n".join(lines).encode()))

    def login(self):
        status, headers, _ = self.call("/api/v1/auth", headers=[f"Authorization: Bearer {self.token}"])
        self.assertEqual(status, 200)
        return headers["set-cookie"].split(";")[0]


def parse(raw):
    head, _, body = raw.partition(b"\r\n\r\n")
    lines = head.decode("latin-1").split("\r\n")
    headers = {}
    for line in lines[1:]:
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return int(lines[0].split()[1]) if lines[0] else 0, headers, body


def assert_policy(case, headers):
    case.assertEqual(headers["content-security-policy"],
                     "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; "
                     "font-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; "
                     "frame-ancestors 'none'; require-trusted-types-for 'script'")
    case.assertEqual(headers["x-frame-options"], "DENY")
    case.assertEqual(headers["referrer-policy"], "no-referrer")
    case.assertEqual(headers["x-content-type-options"], "nosniff")
    case.assertEqual(headers["cross-origin-resource-policy"], "same-origin")
    case.assertFalse([name for name in headers if name.startswith("access-control-")])


class Access(Harness):
    def test_a_request_has_no_token_on_a_network_bind(self):
        self.start(NETWORK)
        status, headers, body = self.call("/api/v1/summary")
        self.assertEqual(status, 401)
        self.assertEqual(json.loads(body)["data"], {"error": "unauthorized"})
        self.assertNotIn("set-cookie", headers)

    def test_a_network_bind_still_serves_the_shell_and_assets(self):
        self.start(NETWORK)
        self.assertEqual(self.call("/")[0], 200)
        self.assertEqual(self.call("/assets/app.js")[0], 200)

    def test_a_wrong_token_is_sent(self):
        self.start(NETWORK)
        status, headers, _ = self.call("/api/v1/auth", headers=["Authorization: Bearer wrong"])
        self.assertEqual(status, 401)
        self.assertNotIn("set-cookie", headers)

    def test_a_non_ascii_token_is_a_plain_failure(self):
        self.start(NETWORK)
        raw = (f"GET /api/v1/auth HTTP/1.1\r\nHost: {self.host}\r\n".encode()
               + b"Authorization: Bearer t\xf6k\xe9n\xff\r\n\r\n")
        self.assertEqual(parse(self.send(raw))[0], 401)

    def test_too_many_failures(self):
        self.start(NETWORK)
        for _ in range(10):
            self.assertEqual(self.call("/api/v1/auth", headers=["Authorization: Bearer no"])[0], 401)
        status, headers, _ = self.call("/api/v1/auth", headers=["Authorization: Bearer no"])
        self.assertEqual(status, 429)
        self.assertGreater(int(headers["retry-after"]), 0)

    def test_a_flood_does_not_lock_a_session_out(self):
        self.start(NETWORK)
        cookie = self.login()
        for _ in range(11):
            self.call("/api/v1/auth", headers=["Authorization: Bearer no"])
        self.assertEqual(self.call("/api/v1/freshness", headers=[f"Cookie: {cookie}"])[0], 200)

    def test_a_bad_cookie_counts_as_a_failure(self):
        self.start(NETWORK)
        name = sec.cookie_name(self.server.port)
        for _ in range(10):
            self.assertEqual(self.call("/api/v1/summary", headers=[f"Cookie: {name}=9.9"])[0], 401)
        self.assertEqual(self.call("/api/v1/summary", headers=[f"Cookie: {name}=9.9"])[0], 429)

    def test_a_correct_token_passes_while_the_limit_is_full(self):
        self.start(NETWORK)
        for _ in range(11):
            self.call("/api/v1/auth", headers=["Authorization: Bearer no"])
        status, headers, _ = self.call("/api/v1/auth", headers=[f"Authorization: Bearer {self.token}"])
        self.assertEqual(status, 200)
        self.assertIn("set-cookie", headers)

    def test_an_expired_cookie_is_no_failed_attempt(self):
        self.start(NETWORK)
        cookie = self.login()
        self.wall.now += 2592000
        for _ in range(12):
            self.assertEqual(self.call("/api/v1/summary", headers=[f"Cookie: {cookie}"])[0], 401)
        self.assertFalse(self.server.failures.blocked())

    def test_the_block_ends_with_the_window(self):
        self.start(NETWORK)
        for _ in range(10):
            self.call("/api/v1/auth", headers=["Authorization: Bearer no"])
        self.clock.now += 60
        self.assertEqual(self.call("/api/v1/auth", headers=["Authorization: Bearer no"])[0], 401)

    def test_the_phone_opens_the_link(self):
        self.start(NETWORK)
        self.assertEqual(self.call("/")[0], 200)
        status, headers, _ = self.call("/api/v1/auth", headers=[f"Authorization: Bearer {self.token}"])
        self.assertEqual(status, 200)
        cookie = headers["set-cookie"]
        for attribute in ("HttpOnly", "SameSite=Strict", "Path=/", "Max-Age=2592000"):
            self.assertIn(attribute, cookie)
        self.assertTrue(cookie.startswith(f"nogg-dash-{self.server.port}="))
        self.assertNotIn(self.token, cookie)
        pair = cookie.split(";")[0]
        self.assertEqual(self.call("/api/v1/auth", headers=[f"Cookie: {pair}"])[0], 200)
        self.assertEqual(self.call("/api/v1/freshness", headers=[f"Cookie: {pair}"])[0], 200)

    def test_the_phone_comes_back_within_thirty_days_and_not_after(self):
        self.start(NETWORK)
        cookie = self.login()
        self.wall.now += 2592000 - 1
        self.assertEqual(self.call("/api/v1/freshness", headers=[f"Cookie: {cookie}"])[0], 200)
        self.wall.now += 2
        self.assertEqual(self.call("/api/v1/summary", headers=[f"Cookie: {cookie}"])[0], 401)

    def test_the_token_is_rotated(self):
        self.start(NETWORK)
        cookie = self.login()
        sec.rotate_secret(self.secret_path)
        self.assertEqual(self.call("/api/v1/summary", headers=[f"Cookie: {cookie}"])[0], 401)
        self.assertEqual(self.call("/api/v1/auth", headers=[f"Authorization: Bearer {self.token}"])[0], 401)
        fresh = sec.read_secret(self.secret_path)
        self.assertEqual(self.call("/api/v1/auth", headers=[f"Authorization: Bearer {fresh}"])[0], 200)

    def test_a_widened_secret_closes_the_door_on_a_running_server(self):
        self.start(NETWORK)
        cookie = self.login()
        self.secret_path.chmod(0o644)
        self.assertEqual(self.call("/api/v1/summary", headers=[f"Cookie: {cookie}"])[0], 401)
        self.assertEqual(self.call("/api/v1/auth", headers=[f"Authorization: Bearer {self.token}"])[0], 401)

    def test_a_loopback_client(self):
        self.start(LOOPBACK)
        self.assertEqual(self.call("/api/v1/freshness")[0], 200)
        status, headers, body = self.call("/api/v1/auth")
        self.assertEqual(status, 200)
        self.assertNotIn("set-cookie", headers)
        self.assertEqual(json.loads(body)["schema"], "nogg.dashboard.auth/v1")


class Requests(Harness):
    def test_a_write_is_attempted(self):
        self.start()
        for method in ("POST", "PUT", "PATCH", "DELETE", "OPTIONS", "TRACE", "BREW"):
            status, headers, _ = self.call("/api/v1/beads", method=method)
            self.assertEqual(status, 405, method)
            self.assertEqual(headers["allow"], "GET, HEAD")
            self.assertNotIn("access-control-allow-origin", headers)

    def test_a_body_on_a_refused_write_does_not_lose_the_answer(self):
        self.start()
        raw = (f"POST /api/v1/beads HTTP/1.1\r\nHost: {self.host}\r\nContent-Length: 200000\r\n\r\n".encode()
               + b"x" * 200000)
        with self.connect() as sock:
            sock.sendall(raw)
            data = b""
            while chunk := sock.recv(65536):       # a reset instead of an end fails here
                data += chunk
        self.assertEqual(parse(data)[0], 405)

    def test_a_refused_client_gets_a_lingering_close(self):
        server = self.start()
        with self.connect() as sock:
            sock.sendall(f"POST / HTTP/1.1\r\nHost: {self.host}\r\nContent-Length: 9\r\n\r\n".encode())
            self.assertEqual(parse(self.read(sock))[0], 405)
            self.assertFalse(server.wait_idle(0.1), "the server stopped reading a client still sending")
        self.assertTrue(server.wait_idle(5))

    def test_a_request_body_is_rejected(self):
        self.start()
        for headers in (["Content-Length: 5"], ["Transfer-Encoding: chunked"], ["Transfer-Encoding:"],
                        ["Content-Length: 0", "Content-Length: 5"], ["Content-Length: x"]):
            self.assertEqual(self.call("/", headers=headers)[0], 400, headers)
        self.assertEqual(self.call("/", headers=["Content-Length: 0"])[0], 200)

    def test_bytes_after_the_head_are_a_body(self):
        self.start()
        raw = f"GET / HTTP/1.1\r\nHost: {self.host}\r\n\r\nsmuggled".encode()
        self.assertEqual(parse(self.send(raw))[0], 400)

    def test_a_malformed_header_cannot_hide_the_rest(self):
        self.start()
        for hiding in ("no colon here\r\n", "\r", "\r\r\n"):
            raw = (f"GET /api/v1/beads HTTP/1.1\r\nHost: {self.host}\r\n{hiding}"
                   "Origin: http://attacker.example\r\nContent-Length: 5\r\n\r\n").encode()
            self.assertEqual(parse(self.send(raw))[0], 400, repr(hiding))

    def test_head_has_headers_and_no_body(self):
        self.start()
        status, headers, body = self.call("/", method="HEAD")
        self.assertEqual((status, body), (200, b""))
        self.assertGreater(int(headers["content-length"]), 0)

    def test_dns_rebinding(self):
        self.start()
        status, _, body = self.call("/api/v1/summary", host="attacker.example")
        self.assertEqual(status, 421)
        self.assertNotIn(b"attacker", body)
        self.assertEqual(self.call("/", host="attacker.example")[0], 421)

    def test_localhost_on_a_loopback_bind(self):
        self.start()
        self.assertEqual(self.call("/", host=f"localhost:{self.server.port}")[0], 200)

    def test_an_allowed_host_is_literal(self):
        self.start(allow_hosts=["dash.example:8742"])
        self.assertEqual(self.call("/", host="dash.example:8742")[0], 200)
        self.assertEqual(self.call("/", host="sub.dash.example:8742")[0], 421)

    def test_a_missing_or_doubled_host(self):
        self.start()
        self.assertEqual(parse(self.send(b"GET / HTTP/1.0\r\n\r\n"))[0], 400)
        self.assertEqual(parse(self.send(b"GET /\r\n\r\n"))[0], 400)
        doubled = f"GET / HTTP/1.1\r\nHost: {self.host}\r\nHost: {self.host}\r\n\r\n"
        self.assertEqual(parse(self.send(doubled.encode()))[0], 400)

    def test_a_cross_site_page_calls_the_api(self):
        self.start()
        self.assertEqual(self.call("/api/v1/beads", headers=["Origin: http://attacker.example"])[0], 403)
        self.assertEqual(self.call("/api/v1/beads", headers=["Sec-Fetch-Site: cross-site"])[0], 403)
        self.assertEqual(self.call("/api/v1/freshness", headers=[f"Origin: http://{self.host}"])[0], 200)
        self.assertEqual(self.call("/api/v1/freshness", headers=["Sec-Fetch-Site: same-origin"])[0], 200)

    def test_path_traversal(self):
        (self.root / "state").mkdir()
        (self.root / "state" / "canary").write_text("canary")
        self.start()
        for path in ("/assets/../../.nogging/state/dashboard/secret", "/assets/../state/canary",
                     "/assets/%2e%2e/state/canary", "/assets/..%2fstate/canary", "//etc/passwd",
                     "/assets/notes.bin", "/assets/", "/assets", "/index.html", "/assets/app.js/",
                     "http://127.0.0.1/assets/app.js", "*"):
            status, _, body = self.call(path)
            self.assertEqual(status, 404, path)
            self.assertNotIn(b"canary", body)

    def test_a_symbolic_link_is_not_served(self):
        static = assets_dir(self.root / "linked")
        (static / "leak.js").symlink_to(self.root / "linked" / "app.js")
        self.assertNotIn("/assets/leak.js", ds.load_assets(static))

    def test_a_malformed_bead_id_has_no_route(self):
        self.start()
        self.assertEqual(self.call("/api/v1/beads/SPEC-bj7s")[0], 501)
        for path in ("/api/v1/beads/a%2fb", "/api/v1/beads/..", "/api/v1/beads/" + "a" * 65,
                     "/api/v1/beads/a/b", "/api/v1/beads/"):
            self.assertEqual(self.call(path)[0], 404, path)

    def forwarded(self, peer, bind):
        class Forwarded(ds.DashboardServer):
            def get_request(self):
                sock, address = super().get_request()
                return sock, (peer, address[1])

        server = self.start(bind, server_class=Forwarded)
        with self.connect() as sock:
            sock.sendall(f"GET / HTTP/1.1\r\nHost: {self.host}\r\n\r\n".encode())
            answer = self.read(sock)
        self.assertTrue(server.wait_idle(5))
        return answer

    def test_a_forwarded_public_peer(self):
        self.assertEqual(self.forwarded("8.8.8.8", LOOPBACK), b"")

    def test_a_forwarded_public_peer_on_a_network_bind(self):
        self.assertEqual(self.forwarded("8.8.8.8", NETWORK), b"")

    def test_a_forwarded_private_peer_reaches_no_tokenless_bind(self):
        self.assertEqual(self.forwarded("10.1.2.3", LOOPBACK), b"")

    def test_a_private_peer_reaches_a_network_bind(self):
        self.assertTrue(self.forwarded("10.1.2.3", NETWORK).startswith(b"HTTP/1.0 200"))

    def test_a_failing_route_is_a_fixed_500(self):
        def broken(server, request):
            raise ValueError("secret detail")

        self.start()
        errors = io.StringIO()
        with mock.patch.object(ds, "ROUTES", ((ds.re.compile("/boom"), broken),)), \
                contextlib.redirect_stderr(errors):
            status, _, body = self.call("/boom")
        self.assertEqual(status, 500)
        self.assertNotIn(b"secret detail", body)
        self.assertNotIn("secret detail", errors.getvalue())
        self.assertIn("ValueError", errors.getvalue())

    def test_nothing_from_the_request_is_echoed(self):
        self.start()
        marker = "ECHO-MARKER"
        for raw in (f"GET /{marker} HTTP/1.1\r\nHost: {self.host}\r\n\r\n",
                    f"GET /?{marker}=1 HTTP/1.1\r\nHost: {marker}\r\n\r\n",
                    f"{marker} / HTTP/1.1\r\nHost: {self.host}\r\n\r\n",
                    f"GET / {marker}\r\n\r\n",
                    f"GET / HTTP/9.9\r\nHost: {self.host}\r\n\r\n",
                    f"GET /a b c {marker}\r\n\r\n",
                    f"GET / HTTP/1.1\r\nHost: {self.host}\r\nOrigin: http://{marker}\r\n\r\n"):
            answer = self.send(raw.encode())
            self.assertNotIn(marker.encode(), answer)
            self.assertTrue(answer.startswith(b"HTTP/1.0 "), answer[:40])


class Responses(Harness):
    def assert_policy(self, headers):
        assert_policy(self, headers)

    def test_headers_on_an_api_response(self):
        self.start()
        for path in ("/api/v1/auth", "/api/v1/freshness", "/api/v1/beads", "/api/v1/changes",
                     "/api/v1/beads/SPEC-x", "/api/v1/summary", "/api/v1/graph?scope=ready"):
            status, headers, _ = self.call(path)
            self.assert_policy(headers)
            self.assertEqual(headers["cache-control"], "no-store", path)
            self.assertIn(status, (200, 501))

    def test_every_refusal_carries_the_policy_too(self):
        self.start()
        for answer in (self.call("/missing"), self.call("/", method="POST"), self.call("/", host="x"),
                       self.call("/", headers=["Origin: http://x"])):
            self.assert_policy(answer[1])

    def test_an_asset_carries_the_policy(self):
        self.start()
        status, headers, _ = self.call("/")
        self.assertEqual(status, 200)
        self.assert_policy(headers)
        self.assertEqual(headers["content-type"], "text/html; charset=utf-8")

    def test_the_server_header_names_no_version(self):
        self.start()
        self.assertNotIn("Python", self.call("/")[1]["server"])

    def test_gzip_to_a_client_that_accepts_it(self):
        self.start()
        status, headers, body = self.call("/assets/app.js", headers=["Accept-Encoding: gzip"])
        self.assertEqual((status, headers["content-encoding"], headers["vary"]), (200, "gzip", "Accept-Encoding"))
        self.assertEqual(gzip.decompress(body), b"// app\n" * 50)
        self.assertLess(len(body), 350)
        status, headers, body = self.call("/assets/app.js")
        self.assertNotIn("content-encoding", headers)
        self.assertEqual(body, b"// app\n" * 50)

    def test_the_gzip_body_carries_no_timestamp(self):
        self.assertEqual(self.assets["/assets/app.js"].gzipped[4:8], b"\0\0\0\0")

    def test_an_image_is_not_compressed_again(self):
        self.start()
        self.assertNotIn("content-encoding", self.call("/assets/images/logo.png", headers=["Accept-Encoding: gzip"])[1])

    def test_a_missing_shell_stops_the_start(self):
        with self.assertRaises(RuntimeError):
            ds.load_assets(self.root)


class Limits(Harness):
    def test_a_slow_client(self):
        server = self.start()
        with self.connect() as sock:
            closed = False
            for byte in range(40):
                try:
                    sock.sendall(b"G")
                except OSError:
                    closed = True
                    break
                self.clock.now += 1
                if select.select([sock], [], [], 0.05)[0]:
                    closed = True
                    break
            self.assertTrue(closed, "the deadline never closed the connection")
            self.assertEqual(self.read(sock), b"")
        self.assertTrue(server.wait_idle(5), "the thread was not freed")

    def test_a_silent_client_is_dropped_at_the_deadline(self):
        server = self.start(read_deadline=0.05)
        with self.connect() as sock:
            sock.sendall(b"GE")
            self.assertEqual(self.read(sock), b"")
        self.assertTrue(server.wait_idle(5))

    def test_an_oversized_header(self):
        self.start()
        status, _, _ = self.call("/", headers=["X-Fill: " + "a" * (ds.MAX_HEADERS + 1)])
        self.assertEqual(status, 431)

    def test_a_flood_of_header_bytes_is_answered_and_closed(self):
        self.start()
        raw = f"GET / HTTP/1.1\r\nHost: {self.host}\r\n".encode() + b"X: " + b"a" * 1_000_000
        self.assertEqual(parse(self.send(raw))[0], 431)

    def test_headers_just_inside_the_limit_pass(self):
        self.start()
        self.assertEqual(self.call("/", headers=["X-Fill: " + "a" * (ds.MAX_HEADERS - 100)])[0], 200)

    def test_an_oversized_request_line(self):
        self.start()
        self.assertEqual(self.call("/" + "a" * (ds.MAX_REQUEST_LINE + 1))[0], 414)

    def test_a_silent_client_cannot_stall_the_accept_loop(self):
        self.start()
        request = f"GET / HTTP/1.1\r\nHost: {self.host}\r\n\r\n".encode()
        held = [self.connect() for _ in range(ds.MAX_THREADS)]
        for sock in held:
            self.addCleanup(sock.close)
            sock.sendall(request[:5])
        silent = self.connect()
        self.addCleanup(silent.close)
        self.assertEqual(parse(self.send(request))[0], 503)
        for sock in held:
            sock.sendall(request[5:])

    def test_many_clients_at_once(self):
        server = self.start()
        request = f"GET / HTTP/1.1\r\nHost: {self.host}\r\n\r\n".encode()
        held = [self.connect() for _ in range(ds.MAX_THREADS)]
        for sock in held:
            self.addCleanup(sock.close)
            sock.sendall(request[:5])
        for _ in range(3):
            status, headers, body = parse(self.send(request))
            self.assertEqual(status, 503)
            self.assertEqual(headers["cache-control"], "no-store")
            assert_policy(self, headers)
            self.assertEqual(body, b'{"error":"busy"}')
        for sock in held:
            sock.sendall(request[5:])
        for sock in held:
            self.assertEqual(parse(self.read(sock))[0], 200)
        self.assertTrue(server.wait_idle(5))
        self.assertEqual(self.call("/")[0], 200)


class Ipv6(unittest.TestCase):
    def test_a_v6_bind_serves_v6_only(self):
        try:
            server = ds.DashboardServer(sec.check_bind("::1"), 0, assets={"/": ds.Response(200, b"shell", api=False)},
                                        readers={})
        except OSError as exc:
            self.skipTest(f"no IPv6 loopback here: {exc}")
        self.addCleanup(server.server_close)
        self.assertEqual(server.socket.getsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY), 1)
        self.assertIn(f"[::1]:{server.port}", server.hosts)
        self.addCleanup(server.shutdown)
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        with socket.create_connection(("::1", server.port), timeout=5) as sock:
            sock.sendall(f"GET / HTTP/1.1\r\nHost: [::1]:{server.port}\r\n\r\n".encode())
            self.assertEqual(parse(Harness.read(sock))[0], 200)

    def test_a_zone_becomes_a_numeric_lookup_and_no_query(self):
        seen = {}

        def getaddrinfo(host, port, family, kind, proto, flags):
            seen.update(host=host, family=family, flags=flags)
            return [(family, kind, proto, "", (host, port, 0, 3))]

        with mock.patch.object(ds.socket, "getaddrinfo", getaddrinfo):
            address = ds.DashboardServer._socket_address(sec.check_bind("fe80::1%eth0"), 9)
        self.assertEqual(address[3], 3)
        self.assertEqual(seen, {"host": "fe80::1%eth0", "family": socket.AF_INET6, "flags": socket.AI_NUMERICHOST})


class Announce(unittest.TestCase):
    secret = "s" * 43

    def stream(self, terminal):
        stream = io.StringIO()
        stream.isatty = lambda: terminal
        return stream

    def test_a_terminal_gets_the_link_in_a_fragment(self):
        stream = self.stream(True)
        ds.announce(NETWORK, 8742, self.secret, stream, which=lambda name: None)
        self.assertIn(f"http://127.0.0.1:8742/#token={self.secret}", stream.getvalue())

    def test_output_is_not_a_terminal(self):
        stream = self.stream(False)
        ds.announce(NETWORK, 8742, self.secret, stream, which=lambda name: "/bin/qrencode")
        self.assertNotIn(self.secret, stream.getvalue())
        self.assertIn("terminal", stream.getvalue())

    def test_a_lan_bind_warns_about_plain_http(self):
        lan = self.stream(False)
        ds.announce(sec.check_bind("192.168.1.5"), 8742, self.secret, lan)
        self.assertIn("WARNING: this bind is plain HTTP", lan.getvalue())

    def test_the_shared_range_names_the_carrier_nat_caveat(self):
        shared = self.stream(False)
        ds.announce(sec.check_bind("100.101.102.103"), 8742, self.secret, shared)
        self.assertIn("carrier NAT", shared.getvalue())
        self.assertNotIn("WARNING", shared.getvalue())

    def test_loopback_prints_no_link(self):
        stream = self.stream(True)
        ds.announce(LOOPBACK, 8742, None, stream)
        self.assertIn("http://127.0.0.1:8742/", stream.getvalue())
        self.assertNotIn("token", stream.getvalue())
        self.assertNotIn("plain HTTP", stream.getvalue())

    def test_the_qr_tool_gets_the_link_on_stdin_only(self):
        seen = {}

        def run(argv, **options):
            seen.update(argv=argv, **options)

        ds.announce(NETWORK, 8742, self.secret, self.stream(True), which=lambda name: "/bin/qrencode", run=run)
        self.assertIn(self.secret, seen["input"])
        self.assertFalse([word for word in seen["argv"] if self.secret in word])

    def test_a_failing_qr_tool_is_no_failure(self):
        def run(argv, **options):
            raise OSError("gone")

        stream = self.stream(True)
        ds.announce(NETWORK, 8742, self.secret, stream, which=lambda name: "/bin/qrencode", run=run)
        self.assertIn(self.secret, stream.getvalue())

    def test_the_link_brackets_ipv6_and_encodes_a_zone(self):
        self.assertEqual(ds.link(sec.check_bind("fd00::1"), 9, "t"), "http://[fd00::1]:9/#token=t")
        self.assertEqual(ds.link(sec.check_bind("fe80::1%eth0"), 9, "t"), "http://[fe80::1%25eth0]:9/#token=t")


class TheTokenNeverReachesALog(unittest.TestCase):
    """A real process, so stdout and stderr are the real thing."""

    def test_the_token_never_reaches_a_server_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            static = assets_dir(Path(tmp) / "static")
            secret_path = Path(tmp) / "state" / "dashboard" / "secret"
            token = sec.ensure_secret(secret_path)
            script = (
                "import sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1])\n"
                "import dashboard_security as sec, dashboard_server as ds\n"
                "ds.serve(sec.Bind('127.0.0.1', None, False), 0, {}, static_dir=sys.argv[2], secret_path=sys.argv[3])\n")
            process = subprocess.Popen(
                [sys.executable, "-c", script, str(Path(__file__).resolve().parent), str(static), str(secret_path)],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                first = process.stdout.readline()
                port = int(first.split(":")[2].split("/")[0])
                host = f"127.0.0.1:{port}"
                for raw in (f"GET /api/v1/auth HTTP/1.1\r\nHost: {host}\r\nAuthorization: Bearer {token}\r\n\r\n",
                            f"GET /api/v1/auth?token={quote(token)} HTTP/1.1\r\nHost: {host}\r\n\r\n",
                            f"GET /{token} HTTP/1.1\r\nHost: {host}\r\n\r\n",
                            f"GET /{token} HTTP/9.9\r\n\r\n",
                            f"{token} / HTTP/1.1\r\n\r\n",
                            f"GET / HTTP/1.1\r\nHost: {token}\r\n\r\n"):
                    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
                        sock.sendall(raw.encode())
                        while sock.recv(65536):
                            pass
                process.terminate()
                rest = process.stdout.read()
                self.assertEqual(process.wait(timeout=10), 0)
            finally:
                process.kill()
                process.stdout.close()
            self.assertNotIn(token, first + rest)
            lines = rest.strip().splitlines()       # the start notes, and no line per request
            self.assertEqual([line.split()[0] for line in lines], ["WARNING:", "The"], rest)


if __name__ == "__main__":
    unittest.main()
