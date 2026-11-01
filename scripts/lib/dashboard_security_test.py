#!/usr/bin/env python3
"""Small tests of the dashboard's security decisions: no socket, no sleep."""
from __future__ import annotations

import os, stat, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_security as sec


class FakeClock:
    def __init__(self, now=1000.0):
        self.now = now

    def __call__(self):
        return self.now


class BindPolicy(unittest.TestCase):
    def refused(self, value):
        with self.assertRaises(sec.BindRefused) as caught:
            sec.check_bind(value)
        return str(caught.exception)

    def test_a_public_address_is_refused(self):
        for value in ("8.8.8.8", "1.1.1.1", "2606:4700::1", "2001:4860:4860::8888"):
            message = self.refused(value)
            self.assertIn(value, message)
            self.assertIn("--list-binds", message)

    def test_the_wildcard_is_refused(self):
        for value in ("0.0.0.0", "::", "0:0:0:0:0:0:0:0"):
            self.assertIn("wildcard", self.refused(value))

    def test_a_mapped_or_borderline_address_is_refused(self):
        for value in ("::ffff:127.0.0.1", "::ffff:10.0.0.1", "100.128.0.1", "100.63.255.255",
                      "172.32.0.1", "172.15.255.255", "192.169.0.1", "169.253.0.1",
                      "11.0.0.1", "126.0.0.1", "128.0.0.1", "224.0.0.1", "255.255.255.255",
                      "ff02::1", "fe00::1", "fec0::1", "64:ff9b::a00:1", "2002:a00:1::",
                      "::127.0.0.1", "0.0.0.1"):
            self.refused(value)

    def test_the_edges_of_every_range_are_accepted(self):
        for value in ("127.0.0.1", "127.255.255.255", "10.0.0.0", "10.255.255.255",
                      "172.16.0.0", "172.31.255.255", "192.168.0.0", "192.168.255.255",
                      "169.254.0.0", "169.254.255.255", "100.64.0.0", "100.127.255.255",
                      "::1", "fc00::", "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"):
            self.assertEqual(sec.check_bind(value).address, value)

    def test_loopback_is_loopback_only(self):
        for value, loopback in (("127.0.0.1", True), ("127.8.8.8", True), ("::1", True),
                                ("10.0.0.1", False), ("100.64.0.1", False), ("fd00::1", False)):
            self.assertIs(sec.check_bind(value).loopback, loopback, value)

    def test_a_hostname_is_refused(self):
        for value in ("localhost", "dashboard.example", "127.1", "2130706433", "0x7f.0.0.1",
                      "", " 127.0.0.1", "127.0.0.1\n", "127.0.0.1:8080", "010.0.0.1"):
            self.assertIn("literal", self.refused(value), repr(value))

    def test_a_link_local_ipv6_address_has_no_zone(self):
        self.assertIn("fe80::1%eth0", self.refused("fe80::1"))
        self.assertIn("zone", self.refused("fe80::1%"))
        self.assertIn("zone", self.refused("fe80::1%eth0/../x"))
        accepted = sec.check_bind("fe80::1%eth0")
        self.assertEqual((accepted.address, accepted.zone, accepted.loopback), ("fe80::1", "eth0", False))

    def test_a_zone_on_anything_else_is_refused(self):
        for value in ("10.0.0.1%eth0", "fd00::1%eth0", "::1%lo"):
            self.assertIn("zone", self.refused(value))

    def test_the_url_form_brackets_ipv6(self):
        self.assertEqual(sec.check_bind("::1").host, "[::1]")
        self.assertEqual(sec.check_bind("127.0.0.1").host, "127.0.0.1")

    def test_a_peer_is_checked_against_the_same_list(self):
        for peer in ("127.0.0.1", "10.1.2.3", "100.100.1.1", "fd00::1", "fe80::1%eth0", "::1"):
            self.assertTrue(sec.peer_allowed(peer), peer)
        for peer in ("8.8.8.8", "::ffff:10.0.0.1", "2606:4700::1", "not-an-address", "", None):
            self.assertFalse(sec.peer_allowed(peer), peer)

    def test_list_binds_is_a_hint_with_a_carrier_nat_warning(self):
        links = [{"ifname": "lo", "addr_info": [{"local": "127.0.0.1"}, {"local": "::1"}]},
                 {"ifname": "eth0", "addr_info": [{"local": "192.168.1.5"}, {"local": "8.8.4.4"},
                                                  {"local": "fe80::1"}, {"local": "100.64.0.9"}]},
                 {"ifname": "tailscale0", "addr_info": [{"local": "100.64.0.8"}]},
                 "junk", {"ifname": "x"}]
        rows = dict(sec.eligible_binds(links))
        self.assertEqual(sorted(rows), ["100.64.0.8", "100.64.0.9", "127.0.0.1", "192.168.1.5",
                                        "::1", "fe80::1%eth0"])
        self.assertIn("carrier NAT", rows["100.64.0.9"])
        self.assertIsNone(rows["100.64.0.8"])
        self.assertEqual(sec.eligible_binds({"unexpected": 1}), [])


class TokenAndCookie(unittest.TestCase):
    secret = sec.new_secret()

    def test_a_new_secret_has_at_least_256_bits(self):
        self.assertGreaterEqual(len(sec.new_secret()), sec.MIN_SECRET_LENGTH)
        self.assertTrue(sec.secret_acceptable(sec.new_secret()))

    def test_an_unusable_secret_never_matches_or_signs_in(self):
        for bad in ("", " ", "\x00" * 64, "short", None, "é" * 64):
            self.assertFalse(sec.secret_acceptable(bad), repr(bad))
            self.assertFalse(sec.token_matches(bad, bad if isinstance(bad, str) else ""))
            self.assertFalse(sec.verify_cookie(bad, sec.sign_cookie("", 2000), 1000))

    def test_constant_time_compare_on_non_ascii(self):
        self.assertTrue(sec.token_matches(self.secret, self.secret))
        for supplied in ("wrong", "tökén", "\udc80", self.secret + "x", self.secret[:-1], "", None):
            self.assertFalse(sec.token_matches(self.secret, supplied), repr(supplied))

    def test_bearer_parsing(self):
        self.assertEqual(sec.bearer_token("Bearer abc"), "abc")
        self.assertEqual(sec.bearer_token("bearer   abc "), "abc")
        for header in (None, "", "Basic abc", "Bearer", "Bearer "):
            self.assertIsNone(sec.bearer_token(header))

    def test_a_cookie_is_not_the_token_and_verifies(self):
        value = sec.sign_cookie(self.secret, 2000)
        self.assertNotIn(self.secret, value)
        self.assertTrue(value.startswith("2000."))
        self.assertTrue(sec.verify_cookie(self.secret, value, 1999))

    def test_a_cookie_expires(self):
        value = sec.sign_cookie(self.secret, 2000)
        self.assertFalse(sec.verify_cookie(self.secret, value, 2000))
        self.assertFalse(sec.verify_cookie(self.secret, value, 2001))

    def test_a_cookie_under_another_secret_is_refused(self):
        value = sec.sign_cookie(sec.new_secret(), 2000)
        self.assertFalse(sec.verify_cookie(self.secret, value, 1000))

    def test_a_tampered_cookie_is_refused(self):
        expiry, mac = sec.sign_cookie(self.secret, 2000).split(".")
        for value in (f"9999.{mac}", f"{expiry}.{'0' * 64}", f"{expiry}.{mac[:-1]}", expiry, "",
                      f"{expiry}.{mac}.x", f"-1.{mac}", f"{expiry}.{mac.upper()}", None):
            self.assertFalse(sec.verify_cookie(self.secret, value, 1000), repr(value))

    def test_set_cookie_attributes(self):
        header = sec.set_cookie_value(8742, self.secret, 1000)
        self.assertTrue(header.startswith("nogg-dash-8742="))
        for attribute in ("HttpOnly", "SameSite=Strict", "Path=/", "Max-Age=2592000"):
            self.assertIn(attribute, header)
        self.assertNotIn(self.secret, header)
        value = header.split(";")[0].split("=", 1)[1]
        self.assertTrue(sec.verify_cookie(self.secret, value, 1000 + 2592000 - 1))
        self.assertFalse(sec.verify_cookie(self.secret, value, 1000 + 2592000))

    def test_cookie_header_parsing(self):
        self.assertEqual(sec.cookie_from_header("a=1; nogg-dash-1=x.y; b=2", "nogg-dash-1"), "x.y")
        self.assertIsNone(sec.cookie_from_header("a=1", "nogg-dash-1"))
        self.assertIsNone(sec.cookie_from_header(None, "nogg-dash-1"))


class TooManyFailures(unittest.TestCase):
    def test_the_eleventh_failure_in_a_minute_is_blocked(self):
        clock = FakeClock()
        limit = sec.FailureLimit(clock=clock)
        for _ in range(10):
            self.assertFalse(limit.blocked())
            limit.record()
        self.assertTrue(limit.blocked())
        self.assertEqual(limit.retry_after(), 60)

    def test_the_window_slides(self):
        clock = FakeClock()
        limit = sec.FailureLimit(clock=clock)
        for _ in range(10):
            limit.record()
            clock.now += 1
        self.assertTrue(limit.blocked())
        self.assertEqual(limit.retry_after(), 50)
        clock.now = 1060.0
        self.assertFalse(limit.blocked())

    def test_a_blocked_flood_cannot_extend_the_block(self):
        clock = FakeClock()
        limit = sec.FailureLimit(clock=clock)
        for _ in range(30):
            limit.record()
        clock.now += 60
        self.assertFalse(limit.blocked())


class HostAndOrigin(unittest.TestCase):
    hosts = sec.allowed_hosts(sec.check_bind("127.0.0.1"), 8742, ["Dash.Example:8742"])

    def test_allowed_hosts_are_exact(self):
        self.assertEqual(self.hosts, {"127.0.0.1:8742", "localhost:8742", "dash.example:8742"})

    def test_localhost_only_on_a_loopback_bind(self):
        hosts = sec.allowed_hosts(sec.check_bind("10.0.0.5"), 8742)
        self.assertEqual(hosts, {"10.0.0.5:8742"})

    def test_ipv6_host_form(self):
        self.assertEqual(sec.allowed_hosts(sec.check_bind("fd00::1"), 9), {"[fd00::1]:9"})

    def test_port_80_is_also_portless(self):
        self.assertEqual(sec.allowed_hosts(sec.check_bind("10.0.0.5"), 80), {"10.0.0.5:80", "10.0.0.5"})

    def test_host_decisions(self):
        self.assertIsNone(sec.host_status(["127.0.0.1:8742"], self.hosts))
        self.assertIsNone(sec.host_status(["LOCALHOST:8742"], self.hosts))
        self.assertEqual(sec.host_status(["attacker.example"], self.hosts), 421)
        self.assertEqual(sec.host_status(["127.0.0.1"], self.hosts), 421)
        self.assertEqual(sec.host_status(["127.0.0.1:1"], self.hosts), 421)
        self.assertEqual(sec.host_status([], self.hosts), 400)
        self.assertEqual(sec.host_status([""], self.hosts), 400)
        self.assertEqual(sec.host_status(["127.0.0.1:8742", "127.0.0.1:8742"], self.hosts), 400)

    def test_origin_decisions(self):
        self.assertTrue(sec.origin_allowed([], [], self.hosts))
        self.assertTrue(sec.origin_allowed(["http://127.0.0.1:8742"], ["same-origin"], self.hosts))
        self.assertTrue(sec.origin_allowed([], ["none"], self.hosts))
        self.assertFalse(sec.origin_allowed(["http://attacker.example"], [], self.hosts))
        self.assertFalse(sec.origin_allowed(["null"], [], self.hosts))
        self.assertFalse(sec.origin_allowed(["https://127.0.0.1:8742"], [], self.hosts))
        self.assertFalse(sec.origin_allowed([], ["cross-site"], self.hosts))
        self.assertFalse(sec.origin_allowed([], ["same-site"], self.hosts))
        self.assertFalse(sec.origin_allowed(["http://127.0.0.1:8742", "http://evil"], [], self.hosts))

    def test_allow_host_refuses_anything_but_a_literal(self):
        for value in ("*", "*.example", "http://dash.example", "dash.example/x", "a b", "", "dash.example:"):
            with self.assertRaises(sec.BindRefused):
                sec.check_allow_host(value)
        self.assertEqual(sec.check_allow_host("Dash.Example"), "dash.example")
        self.assertEqual(sec.check_allow_host("[FD00::1]:8742"), "[fd00::1]:8742")

    def test_gzip_negotiation(self):
        for header, expected in (("gzip", True), ("br, gzip;q=0.5", True), ("gzip;q=0", False),
                                 ("gzip; q=0.000", False), ("deflate", False), (None, False), ("", False)):
            self.assertIs(sec.accepts_gzip(header), expected, header)

    def test_bead_id_form(self):
        for good in ("SPEC-bj7s", "SPEC-6puu.1", "my_repo-a1"):
            self.assertTrue(sec.BEAD_ID.match(good))
        for bad in ("../secret", "a/b", "", "-a", "a" * 65, "a b", "a%2fb"):
            self.assertIsNone(sec.BEAD_ID.match(bad), bad)


class SecretFile(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name) / "dashboard"
        self.path = self.dir / "secret"

    def test_it_is_created_0600_in_0700_and_survives_a_restart(self):
        first = sec.ensure_secret(self.path)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.dir.stat().st_mode), 0o700)
        self.assertEqual(sec.ensure_secret(self.path), first)

    def test_a_umask_cannot_widen_it(self):
        previous = os.umask(0)
        self.addCleanup(os.umask, previous)
        sec.ensure_secret(self.path)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.dir.stat().st_mode), 0o700)

    def test_a_wider_mode_is_refused_and_named(self):
        sec.ensure_secret(self.path)
        self.path.chmod(0o644)
        with self.assertRaises(sec.SecretRefused) as caught:
            sec.ensure_secret(self.path)
        self.assertIn(str(self.path), str(caught.exception))
        self.assertIn("0600", str(caught.exception))

    def test_an_open_directory_is_refused(self):
        sec.ensure_secret(self.path)
        self.dir.chmod(0o755)
        with self.assertRaises(sec.SecretRefused) as caught:
            sec.ensure_secret(self.path)
        self.assertIn("0700", str(caught.exception))

    def test_a_symlink_is_refused(self):
        self.dir.mkdir(mode=0o700)
        target = Path(self.tmp.name) / "elsewhere"
        target.write_text(sec.new_secret())
        target.chmod(0o600)
        self.path.symlink_to(target)
        with self.assertRaises(sec.SecretRefused):
            sec.read_secret(self.path)

    def test_a_zeroed_or_empty_secret_is_refused_not_used(self):
        for content in (b"", b"\0" * 44, b"short\n"):
            self.dir.mkdir(mode=0o700, exist_ok=True)
            self.path.unlink(missing_ok=True)
            self.path.write_bytes(content)
            self.path.chmod(0o600)
            with self.assertRaises(sec.SecretRefused) as caught:
                sec.read_secret(self.path)
            self.assertIn("--rotate-token", str(caught.exception))

    def test_a_missing_secret_reads_as_none_and_creates_nothing(self):
        self.assertIsNone(sec.read_secret(self.path))
        self.assertFalse(self.dir.exists())

    def test_rotation_replaces_it_and_recovers_an_open_or_broken_file(self):
        first = sec.ensure_secret(self.path)
        self.path.chmod(0o644)
        sec.rotate_secret(self.path)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertNotEqual(sec.read_secret(self.path), first)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["secret"])

    def test_rotation_clears_a_leftover_temporary_file(self):
        sec.ensure_secret(self.path)
        (self.dir / "secret.new").write_text("left by a crash")
        sec.rotate_secret(self.path)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["secret"])

    def test_mode_problem_is_silent_when_unused_or_safe(self):
        self.assertIsNone(sec.mode_problem(self.path))
        sec.ensure_secret(self.path)
        self.assertIsNone(sec.mode_problem(self.path))
        self.path.chmod(0o640)
        self.assertIn("0640", sec.mode_problem(self.path))

    def test_a_watch_follows_rotation_and_closes_on_trouble(self):
        first = sec.ensure_secret(self.path)
        watch = sec.SecretWatch(self.path, first)
        self.assertEqual(watch.current(), first)
        sec.rotate_secret(self.path)
        rotated = watch.current()
        self.assertNotEqual(rotated, first)
        self.path.chmod(0o644)
        self.assertIsNone(watch.current())
        self.path.unlink()
        self.assertIsNone(watch.current())


class ResponseHeaders(unittest.TestCase):
    def test_api_and_asset_policies(self):
        api, asset = dict(sec.security_headers(True)), dict(sec.security_headers(False))
        self.assertEqual(api["Cache-Control"], "no-store")
        self.assertNotEqual(asset["Cache-Control"], "no-store")
        self.assertIn("require-trusted-types-for 'script'", api["Content-Security-Policy"])
        self.assertEqual(api["X-Frame-Options"], "DENY")


if __name__ == "__main__":
    unittest.main()
