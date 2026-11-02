#!/usr/bin/env python3
"""Tests of the consented dashboard service: the consent record, the audit trail, the
unit text, the enable/disable/run/status steps and the doctor lines.

Offline: a fake host stands in for `systemctl`, `loginctl` and `systemd-cat`, cgroup text
is injected, no unit is installed and no sleep runs. The one real server binds loopback
under a network-rules `Bind`, and closes before the test ends."""
from __future__ import annotations

import io, json, os, socket, stat, subprocess, sys, tempfile, threading, unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_security as sec
import dashboard_server as server
import dashboard_service as svc

UNIT_CGROUP = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/nogg-dashboard-repo.service\n"
APP_CGROUP = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/run-u7.scope\n"
OPERATOR = svc.Caller(refusal=None, session=None, stdout_tty=True)


class FakeHost(svc.Host):
    """Records every command; answers `is-enabled`, `is-active` and `loginctl` from fields."""

    def __init__(self, *, systemctl=True, enabled="disabled", active="inactive", linger="no", journal=True):
        self.calls, self.inputs = [], []
        self.enabled, self.active, self.linger = enabled, active, linger
        self.present = {"systemctl": systemctl, "systemd-cat": journal, "loginctl": True}
        super().__init__(run=self._run, which=lambda name: f"/stub/{name}" if self.present.get(name) else None)

    def _run(self, argv, input=None):
        self.calls.append(list(argv))
        if argv[:3] == ["systemctl", "--user", "disable"] and getattr(self, "fail_disable", False):
            return subprocess.CompletedProcess(argv, 1, "", "Failed to connect to bus")
        if input is not None:
            self.inputs.append(input)
        out, code = "", 0
        if argv[:2] == ["systemctl", "--user"] and argv[2] == "is-enabled":
            out, code = self.enabled + "\n", 0 if self.enabled == "enabled" else 1
        elif argv[:2] == ["systemctl", "--user"] and argv[2] == "is-active":
            out, code = self.active + "\n", 0 if self.active == "active" else 3
        elif argv[0] == "loginctl":
            out = f"Linger={self.linger}\n"
        return subprocess.CompletedProcess(argv, code, out, "")

    def systemctl_calls(self):
        """The calls that change something: the `is-*` queries left out."""
        return [call[2:] for call in self.calls if call[:2] == ["systemctl", "--user"]
                and not call[2].startswith("is-")]


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="nogg service ")
        root = Path(self.tmp.name)
        self.workdir = root / "repo"
        self.workdir.mkdir()
        self.paths = svc.Paths(state=root / "repo/.nogging/state/dashboard", unit_dir=root / "config/systemd/user",
                               slug="repo", workdir=self.workdir, name="repo")

    def tearDown(self):
        self.tmp.cleanup()

    def consent(self, **changes):
        record = svc.consent_record("100.86.79.27", 8742, [], "2026-11-02T10:00:00Z", "/dev/pts/3")
        record.update(changes)
        svc.write_consent(self.paths.consent, record)
        return record

    def files(self):
        root = Path(self.tmp.name)
        return sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file() or p.is_symlink())


class Consent(Fixture):
    def test_a_round_trip(self):
        record = self.consent(allow_hosts=["dash.tailnet.example"])
        self.assertEqual(svc.read_consent(self.paths.consent), record)
        self.assertEqual(stat.S_IMODE(self.paths.consent.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.paths.state.stat().st_mode), 0o700)
        self.assertFalse(self.paths.consent.with_name("consent.json.new").exists())

    def refused(self):
        with self.assertRaises(svc.ServiceRefused) as caught:
            svc.read_consent(self.paths.consent)
        self.assertEqual(caught.exception.code, svc.EX_CONFIG)
        self.assertIn("nogg dashboard service enable", str(caught.exception))
        return str(caught.exception)

    def test_no_consent(self):
        self.assertIn("no consent", self.refused())

    def test_an_open_mode_is_tampered(self):
        self.consent()
        self.paths.consent.chmod(0o644)
        self.assertIn("0644", self.refused())

    def test_a_public_or_wildcard_address_is_tampered(self):
        for address in ("8.8.8.8", "0.0.0.0", "127.0.0.1", "dash.example"):
            self.consent(bind=address)
            self.assertIn("consent", self.refused(), address)

    def test_a_schema_change_is_tampered(self):
        for changes in ({"schema": "nogg.dashboard.consent/v2"}, {"port": True}, {"port": 70000},
                        {"allow_hosts": ["*.example"]}, {"tty": 7}, {"tty": "pts/3\x1b[2J"},
                        {"at": "yesterday"}):
            self.consent(**changes)
            self.refused()
        record = self.consent()
        self.paths.consent.write_text(json.dumps({**record, "token": "x"}))
        self.paths.consent.chmod(0o600)
        self.assertIn("schema", self.refused())
        self.paths.consent.write_text("{not json")
        self.refused()

    def test_a_symlink_or_an_open_directory_is_tampered(self):
        record = self.consent()
        target = Path(self.tmp.name) / "elsewhere.json"
        target.write_text(json.dumps(record))
        target.chmod(0o600)
        self.paths.consent.unlink()
        self.paths.consent.symlink_to(target)
        self.refused()
        self.paths.consent.unlink()
        self.consent()
        self.paths.state.chmod(0o755)
        self.assertIn("0700", self.refused())


class Unit(Fixture):
    def test_the_unit_text(self):
        text = svc.render_unit("repo", Path("/home/op/my repo"))
        self.assertIn("WorkingDirectory=/home/op/my repo\n", text)
        self.assertIn('ExecStart="/home/op/my repo/scripts/nogg" dashboard service run\n', text)
        for line in ("LimitCORE=0", "RestartPreventExitStatus=78 203", "Restart=on-failure", "UMask=0077",
                     "StartLimitIntervalSec=0", "WantedBy=default.target"):
            self.assertIn(line + "\n", text)

    def test_a_specifier_is_escaped_and_a_quote_refused(self):
        self.assertIn("WorkingDirectory=/srv/100%%\n", svc.render_unit("repo", Path("/srv/100%")))
        for bad in ('/srv/a"b', "/srv/a\\b", "/srv/a\nb", "/srv/a ", "/srv/$HOME"):
            with self.assertRaises(svc.ServiceRefused):
                svc.render_unit("repo", Path(bad))
        with self.assertRaises(svc.ServiceRefused):
            svc.render_unit("repo", Path("relative"))


class AuditTrail(Fixture):
    def test_each_event_holds_only_its_fields(self):
        audit = svc.Audit(self.paths.audit, clock=lambda: __import__("datetime").datetime(2026, 11, 2,
                          tzinfo=__import__("datetime").timezone.utc))
        audit.append("consent", bind="100.86.79.27", port=8742, tty="/dev/pts/3")
        audit.append("started", mode="terminal", bind="10.0.0.5", port=8742, pid=42)
        audit.append("stopped")
        audit.append("revoked", caller="orchestrator:nogg-orchestrator-repo")
        audit.append("rotated")
        rows = [json.loads(line) for line in self.paths.audit.read_text().splitlines()]
        self.assertEqual([row["event"] for row in rows], ["consent", "started", "stopped", "revoked", "rotated"])
        self.assertEqual(rows[0], {"at": "2026-11-02T00:00:00Z", "event": "consent", "bind": "100.86.79.27",
                                   "port": 8742, "tty": "/dev/pts/3"})
        self.assertEqual(set(rows[2]), {"at", "event"})
        self.assertEqual(stat.S_IMODE(self.paths.audit.stat().st_mode), 0o600)
        for event, fields in (("rotated", {"token": "x"}), ("stopped", {"secret": "x"}), ("nonsense", {})):
            with self.assertRaises(ValueError):
                audit.append(event, **fields)
        self.assertEqual(len(self.paths.audit.read_text().splitlines()), 5)

    def test_one_write_per_line_on_an_append_descriptor(self):
        audit = svc.Audit(self.paths.audit)
        audit.append("rotated")
        writes, flags = [], []
        real_write, real_open = os.write, os.open
        def counting_write(fd, data):
            writes.append(data)
            return real_write(fd, data)
        def recording_open(path, flag, *rest):
            if str(path) == str(self.paths.audit):
                flags.append(flag)
            return real_open(path, flag, *rest)
        with mock.patch.object(svc.os, "write", counting_write), mock.patch.object(svc.os, "open", recording_open):
            audit.append("started", mode="service", bind="100.86.79.27", port=8742, pid=7,
                         consent_at="2026-11-02T10:00:00Z", tty="/dev/pts/3")
        self.assertEqual(len(writes), 1)
        self.assertTrue(writes[0].endswith(b"\n") and writes[0].count(b"\n") == 1)
        self.assertTrue(flags[0] & os.O_APPEND)
        self.assertEqual(len(self.paths.audit.read_text().splitlines()), 2)

    def test_a_wider_file_is_narrowed_and_the_mirror_sees_a_failed_line(self):
        svc.Audit(self.paths.audit).append("rotated")
        self.paths.audit.chmod(0o644)
        svc.Audit(self.paths.audit).append("rotated")
        self.assertEqual(stat.S_IMODE(self.paths.audit.stat().st_mode), 0o600)
        mirror = io.StringIO()
        self.paths.audit.unlink()
        self.paths.audit.mkdir()
        with self.assertRaises(OSError):
            svc.Audit(self.paths.audit, mirror=mirror).append("stopped")
        self.assertIn('"event":"stopped"', mirror.getvalue())

    def test_the_journal_gets_a_cli_line(self):
        host = FakeHost()
        svc.Audit(self.paths.audit, journal=svc.journal_sender(host)).append("rotated")
        self.assertEqual(host.calls, [["systemd-cat", "-t", "nogg-dashboard"]])
        self.assertIn('"event":"rotated"', host.inputs[0])
        self.assertIsNone(svc.journal_sender(FakeHost(journal=False)))


class Enable(Fixture):
    def enable(self, caller=OPERATOR, host=None, address="100.86.79.27", typed=None, **kwargs):
        host = host or FakeHost()
        out = io.StringIO()
        typed = address if typed is None else typed
        result = svc.enable(self.paths, host, caller, address=address, port=8742, allow_hosts=kwargs.get("hosts", []),
                            confirm=lambda: (typed + "\n", "/dev/pts/3"), out=out)
        return result, host, out.getvalue()

    def test_the_operator_enables_the_service(self):
        record, host, output = self.enable(host=FakeHost(linger="no"))
        self.assertEqual(svc.read_consent(self.paths.consent), record)
        self.assertEqual(record["tty"], "/dev/pts/3")
        self.assertEqual(host.systemctl_calls(), [["daemon-reload"], ["enable", "--now", "nogg-dashboard-repo.service"]])
        self.assertIn("ExecStart=", self.paths.unit_path.read_text())
        rows = [json.loads(line) for line in self.paths.audit.read_text().splitlines()]
        self.assertEqual([(r["event"], r["bind"], r["port"], r["tty"]) for r in rows],
                         [("consent", "100.86.79.27", 8742, "/dev/pts/3")])
        secret = self.paths.secret.read_text().strip()
        self.assertTrue(secret)
        for text in (self.paths.unit_path.read_text(), self.paths.consent.read_text(), output,
                     json.dumps(host.calls), "".join(host.inputs)):
            self.assertTrue(secret not in text, "the secret reached a written or printed text")
        self.assertIn("lingering is off", output)
        self.assertIn("NOTE: this is plain HTTP", output)

    def test_a_second_enable_replaces_and_restarts(self):
        self.enable()
        _, host, _ = self.enable(address="10.1.2.3")
        self.assertIn(["restart", "nogg-dashboard-repo.service"], host.systemctl_calls())
        self.assertEqual(svc.read_consent(self.paths.consent)["bind"], "10.1.2.3")
        self.assertEqual(len(self.paths.audit.read_text().splitlines()), 2)

    def assert_nothing(self, host):
        self.assertEqual(self.files(), [])
        self.assertEqual(host.systemctl_calls(), [])

    def test_refusals_write_nothing_and_call_no_systemctl(self):
        cases = [
            (svc.Caller(refusal="it runs inside supervised session lead-x", stdout_tty=True), {}, "lead-x"),
            (svc.Caller(refusal="stdin is not a terminal", stdout_tty=True), {}, "stdin"),
            (svc.Caller(refusal=None, stdout_tty=False), {}, "stdout"),
            (OPERATOR, {"address": "127.0.0.1"}, "loopback"),
            (OPERATOR, {"address": "8.8.8.8"}, "8.8.8.8"),
            (OPERATOR, {"host": FakeHost(systemctl=False)}, "nogg dashboard --bind 100.86.79.27"),
            (OPERATOR, {"typed": "100.86.79.28"}, "does not match"),
        ]
        for caller, kwargs, expected in cases:
            host = kwargs.pop("host", FakeHost())
            with self.assertRaises((svc.ServiceRefused, sec.BindRefused)) as caught:
                self.enable(caller=caller, host=host, **kwargs)
            self.assertIn(expected, str(caught.exception))
            self.assert_nothing(host)

    def test_an_active_unit_without_a_consent_is_restarted(self):
        _, host, _ = self.enable(host=FakeHost(active="active"))
        self.assertIn(["restart", "nogg-dashboard-repo.service"], host.systemctl_calls())

    def test_an_open_secret_or_an_unwritable_trail_records_no_consent(self):
        sec.rotate_secret(self.paths.secret)
        self.paths.secret.chmod(0o644)
        host = FakeHost()
        with self.assertRaises(svc.ServiceRefused) as caught:
            self.enable(host=host)
        self.assertIn("0644", str(caught.exception))
        self.assertFalse(self.paths.consent.exists() or self.paths.unit_path.exists())
        self.assertEqual(host.systemctl_calls(), [])
        self.paths.secret.chmod(0o600)
        self.paths.audit.mkdir()
        with self.assertRaises(svc.ServiceRefused) as caught:
            self.enable(host=host)
        self.assertIn("cannot be recorded", str(caught.exception))
        self.assertFalse(self.paths.consent.exists() or self.paths.unit_path.exists())
        self.assertEqual(host.systemctl_calls(), [])

    def test_a_long_socket_path_is_warned(self):
        deep = svc.Paths(state=Path("/" + "d" * 120) / "dashboard", unit_dir=self.paths.unit_dir, slug="repo",
                         workdir=self.workdir)
        self.assertIn("107", svc.socket_path_warning(deep))
        self.assertIsNone(svc.socket_path_warning(self.paths))


class Disable(Fixture):
    def disable(self, caller, host=None):
        host = host or FakeHost(enabled="enabled", active="active")
        out = io.StringIO()
        return svc.disable(self.paths, host, caller, out=out), host

    def install(self):
        record, host, _ = Enable.enable(self)
        return record

    def test_the_orchestrator_switches_it_off(self):
        self.install()
        orchestrator = svc.Caller(session={"name": "nogg-orchestrator-repo", "role": "orchestrator"},
                                  refusal="it runs inside supervised session nogg-orchestrator-repo")
        changed, host = self.disable(orchestrator)
        self.assertTrue(changed)
        self.assertFalse(self.paths.unit_path.exists() or self.paths.consent.exists())
        self.assertEqual(host.systemctl_calls()[-2:], [["disable", "--now", "nogg-dashboard-repo.service"],
                                                       ["daemon-reload"]])
        last = json.loads(self.paths.audit.read_text().splitlines()[-1])
        self.assertEqual((last["event"], last["caller"]), ("revoked", "orchestrator:nogg-orchestrator-repo"))

    def test_a_lead_or_an_unproven_caller_is_refused(self):
        self.install()
        before = self.files()
        for caller in (svc.Caller(session={"name": "lead-x", "role": "lead"}, refusal="inside lead-x"),
                       svc.Caller(session_error="session made-up is not a known supervised session"),
                       svc.Caller(refusal="stdin is not a terminal")):
            with self.assertRaises(svc.ServiceRefused):
                self.disable(caller)
        self.assertEqual(self.files(), before)

    def test_a_failed_stop_is_no_revocation(self):
        self.install()
        host = FakeHost(enabled="enabled", active="active")
        host.fail_disable = True
        with self.assertRaises(svc.ServiceRefused) as caught:
            self.disable(OPERATOR, host)
        self.assertIn("systemctl --user stop nogg-dashboard-repo.service", str(caught.exception))
        self.assertFalse(self.paths.consent.exists())
        self.assertTrue(self.paths.unit_path.exists())
        self.assertNotIn("revoked", self.paths.audit.read_text())
        changed, _ = self.disable(OPERATOR)
        self.assertTrue(changed and not self.paths.unit_path.exists())
        self.assertIn("revoked", self.paths.audit.read_text())

    def test_disabled_twice(self):
        changed, host = self.disable(OPERATOR, FakeHost())
        self.assertFalse(changed)
        self.assertEqual(self.files(), [])
        self.assertNotIn(["disable", "--now", "nogg-dashboard-repo.service"], host.systemctl_calls())


class Run(Fixture):
    def run_service(self, caller=svc.Caller(), cgroup=UNIT_CGROUP):
        served, out = [], io.StringIO()
        def serve(bind, port, hosts, on_start, on_stop, audit, control):
            served.append((bind, port, hosts))
            on_start(port)
            on_stop()
        svc.run(self.paths, caller, cgroup=lambda: cgroup, serve=serve, out=out)
        return served, out.getvalue()

    def refused(self, **kwargs):
        with self.assertRaises(svc.ServiceRefused) as caught:
            self.run_service(**kwargs)
        self.assertEqual(caught.exception.code, svc.EX_CONFIG)
        return str(caught.exception)

    def test_no_consent_and_a_tampered_consent(self):
        self.assertIn("nogg dashboard service enable", self.refused())
        self.consent()
        self.paths.consent.chmod(0o644)
        self.refused()
        for address in ("8.8.8.8", "0.0.0.0"):
            self.consent(bind=address)
            self.refused()
        self.assertFalse(self.paths.control.exists())

    def test_a_start_beside_the_unit(self):
        self.consent()
        self.assertIn("app.slice/run-u7.scope", self.refused(cgroup=APP_CGROUP))
        self.assertIn("(none)", self.refused(cgroup=""))

    def test_the_service_inside_a_session(self):
        self.consent()
        message = self.refused(caller=svc.Caller(session={"name": "lead-x", "role": "lead"}))
        self.assertIn("inside a supervised session", message)
        self.refused(caller=svc.Caller(session_error="session made-up is not a known supervised session"))

    def test_it_serves_exactly_the_consent(self):
        self.consent(bind="10.0.0.5", port=9000, allow_hosts=["dash.lan"])
        served, output = self.run_service()
        self.assertEqual([(b.address, p, h) for b, p, h in served], [("10.0.0.5", 9000, ["dash.lan"])])
        rows = [json.loads(line) for line in self.paths.audit.read_text().splitlines()]
        self.assertEqual([r["event"] for r in rows], ["started", "stopped"])
        self.assertEqual((rows[0]["mode"], rows[0]["consent_at"], rows[0]["tty"]),
                         ("service", "2026-11-02T10:00:00Z", "/dev/pts/3"))
        self.assertEqual(output.splitlines(), self.paths.audit.read_text().splitlines())

    def test_only_the_user_managers_unit_cgroup_counts(self):
        self.consent()
        for text in ("0::/user.slice/user-1000.slice/session-3.scope/nogg-dashboard-repo.service\n",
                     "0::/nogg-dashboard-repo.service\n",
                     "0::/user.slice/user-1000.slice/user@1000.service/app.slice/x.scope/nogg-dashboard-repo.service\n"):
            self.refused(cgroup=text)
        served, _ = self.run_service(cgroup="0::/user.slice/user-1000.slice/user@1000.service/nogg-dashboard-repo.service\n")
        self.assertEqual(len(served), 1)

    def test_no_cgroup_on_the_host_skips_that_check(self):
        self.consent()
        served, _ = self.run_service(cgroup=None)
        self.assertEqual(len(served), 1)


class StatusAndDoctor(Fixture):
    def test_status_writes_nothing(self):
        self.consent()
        svc.Audit(self.paths.audit).append("rotated")
        before = {p: p.stat().st_mtime_ns for p in Path(self.tmp.name).rglob("*")}
        out = io.StringIO()
        svc.status(self.paths, FakeHost(enabled="enabled", active="active"), out=out, cgroup_applies=True,
                   journal_is_persistent=False)
        text = out.getvalue()
        self.assertIn("100.86.79.27 port 8742", text)
        self.assertIn("enabled=enabled, active=active", text)
        self.assertIn("volatile", text)
        self.assertIn('"event":"rotated"', text)
        self.assertEqual(before, {p: p.stat().st_mtime_ns for p in Path(self.tmp.name).rglob("*")})
        out = io.StringIO()
        self.paths.consent.unlink()
        svc.status(self.paths, FakeHost(systemctl=False), out=out, cgroup_applies=False, journal_is_persistent=True)
        self.assertIn("no exposure is consented", out.getvalue())

    def test_doctor_on_an_unused_install(self):
        host = FakeHost()
        self.assertEqual(svc.doctor_lines(self.paths, host), ([], []))
        self.assertEqual(host.calls, [])

    def test_doctor_with_a_unit_and_no_consent(self):
        self.paths.unit_dir.mkdir(parents=True)
        self.paths.unit_path.write_text(svc.render_unit("repo", self.workdir))
        warnings, notes = svc.doctor_lines(self.paths, FakeHost(enabled="enabled", active="active"))
        self.assertEqual(len(warnings), 1)
        self.assertIn("nogg dashboard service disable", warnings[0])

    def test_doctor_with_a_consented_service(self):
        Enable.enable(self)
        warnings, notes = svc.doctor_lines(self.paths, FakeHost(enabled="enabled", active="active"))
        self.assertEqual(warnings, [])
        self.assertIn("100.86.79.27 port 8742", notes[0])

    def test_doctor_with_an_open_consent(self):
        Enable.enable(self)
        self.paths.consent.chmod(0o644)
        warnings, _ = svc.doctor_lines(self.paths, FakeHost(enabled="enabled", active="active"))
        self.assertTrue(any("0644" in w for w in warnings))
        self.assertTrue(any("nogg dashboard service disable" in w for w in warnings))

    def test_doctor_with_a_consent_and_no_unit(self):
        self.consent()
        warnings, notes = svc.doctor_lines(self.paths, FakeHost())
        self.assertEqual(warnings, [])
        self.assertIn("not installed", notes[0])


class Serving(Fixture):
    """Medium: the real server on a network-rules bind of loopback, closed in the test."""

    def serve(self, on_start, service=True):
        stop, out = threading.Event(), io.StringIO()
        bind = sec.Bind("127.0.0.1", None, False)
        static = Path(self.tmp.name) / "static"
        static.mkdir(exist_ok=True)
        (static / "index.html").write_text("<!doctype html><title>t</title>")
        ports = []
        def started(port):
            ports.append(port)
            on_start(port)
            stop.set()
        server.serve(bind, 0, {}, static_dir=static, secret_path=self.paths.secret, stop=stop, stream=out,
                     service=service, on_start=started, on_stop=lambda: ports.append("stopped"))
        return out.getvalue(), ports

    def test_the_service_prints_no_token(self):
        output, ports = self.serve(lambda port: None)
        secret = self.paths.secret.read_text().strip()
        self.assertIn(f"http://127.0.0.1:{ports[0]}/", output)
        self.assertIn("nogg dashboard pair", output)
        self.assertTrue(secret not in output and "#token=" not in output, "the service printed a token")
        self.assertEqual(ports[-1], "stopped")

    def test_an_exposure_that_cannot_be_recorded_does_not_start(self):
        def fail(port):
            raise RuntimeError("audit refused")
        seen = []
        bind = sec.Bind("127.0.0.1", None, False)
        static = Path(self.tmp.name) / "static"
        static.mkdir()
        (static / "index.html").write_text("<!doctype html>")
        def started(port):
            seen.append(port)
            fail(port)
        with self.assertRaises(RuntimeError):
            server.serve(bind, 0, {}, static_dir=static, secret_path=self.paths.secret, stream=io.StringIO(),
                         on_start=started)
        import socket
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection(("127.0.0.1", seen[0]), timeout=60).close()



class Control(unittest.TestCase):
    """The control socket and `pair`, with a short socket path under /tmp. A real server binds
    loopback under the network rules; peer credentials are stubbed only at the socket boundary."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ndc-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.paths = svc.Paths(state=root / "dashboard", unit_dir=root / "units", slug="repo", workdir=root, name="r")
        sec.ensure_secret(self.paths.secret)
        self.events, self.closers = [], []

    def start(self, audit=None, **options):
        static = Path(self.tmp.name) / "static"
        static.mkdir(exist_ok=True)
        (static / "index.html").write_text("<!doctype html>")
        watch = sec.SecretWatch(self.paths.secret, sec.read_secret(self.paths.secret))
        self.server = server.DashboardServer(sec.Bind("127.0.0.1", None, False), 0,
                                             assets=server.load_assets(static), readers={}, secret=watch,
                                             pairing=sec.PairingStore(),
                                             audit=audit or (lambda event, **f: self.events.append((event, f))))
        self.addCleanup(self.server.server_close)
        control = svc.ControlServer(self.paths.control, svc.control_answer(self.server), **options)
        self.addCleanup(control.open())
        return control

    def pair(self, caller=svc.Caller(), request=svc.control_request):
        out = io.StringIO()
        reply = svc.pair(self.paths, caller, out=out, request=request)
        return reply, out.getvalue()

    def test_the_operator_mints_a_link(self):
        self.start()
        reply, output = self.pair()
        link, expiry = output.splitlines()
        self.assertRegex(link, rf"^http://127\.0\.0\.1:{self.server.port}/#pair=[0-9a-f]{{32}}$")
        self.assertIn("expires at", expiry)
        event, fields = self.events[0]
        self.assertEqual((event, fields["caller"], fields["peer_pid"]), ("link_minted", "operator", os.getpid()))
        self.assertNotIn(link.split("=", 1)[1], repr(self.events))
        self.assertEqual(stat.S_IMODE(self.paths.control.lstat().st_mode), 0o600)

    def test_the_orchestration_agent_mints_a_link(self):
        self.start()
        orchestrator = svc.Caller(refusal="it runs inside supervised session nogg-orchestrator-r",
                                  session={"name": "nogg-orchestrator-r", "role": "orchestrator"})
        self.pair(orchestrator)
        self.assertEqual(self.events[0][1]["caller"], "orchestrator:nogg-orchestrator-r")

    def test_a_refused_caller_never_connects(self):
        self.start()
        connects = []
        callers = (svc.Caller(session={"name": "lead-x", "role": "lead"}),
                   svc.Caller(session={"name": "loop-x", "role": "loop"}),
                   svc.Caller(session_error="NOGG_SESSION_NAME=made-up names no proven session"),
                   svc.Caller(refusal="stdin is not a terminal"))
        for caller in callers:
            with self.assertRaises(svc.ServiceRefused):
                self.pair(caller, request=lambda *args: connects.append(args))
        self.assertEqual((connects, self.events), ([], []))

    def test_no_service_runs(self):
        with self.assertRaises(svc.ServiceRefused) as caught:
            self.pair()
        self.assertIn("nogg dashboard service enable --bind <address>", str(caught.exception))
        self.assertIn("not reachable", svc.running_report(self.paths))
        self.assertFalse(svc.service_answers(self.paths))

    def test_a_fourth_link(self):
        self.start()
        outputs = [self.pair()[1] for _ in range(4)]
        self.assertTrue(all("ended" not in output for output in outputs[:3]))
        self.assertIn("it ended 1 older open link", outputs[3])
        self.assertIn("3 open pairing links", svc.running_report(self.paths))

    def test_the_audit_trail_cannot_be_written(self):
        def broken(event, **fields):
            raise OSError("read-only")
        self.start(audit=broken)
        with self.assertRaises(svc.ServiceRefused) as caught:
            self.pair()
        self.assertIn("no link was minted", str(caught.exception))
        self.assertNotIn("#pair=", str(caught.exception))
        self.assertEqual(self.server.pairing_status()["open_links"], 0)

    def test_status_holds_no_code(self):
        self.start()
        reply, output = self.pair()
        report = svc.running_report(self.paths)
        self.assertIn(f"running on 127.0.0.1 port {self.server.port}", report)
        self.assertIn("1 open pairing link,", report)
        self.assertNotIn(output.splitlines()[0].split("=", 1)[1], report)
        self.assertTrue(svc.service_answers(self.paths))

    def test_another_user_connects(self):
        self.start(credentials=lambda connection: (4242, os.geteuid() + 1, 0))
        with self.assertRaises(svc.ServiceRefused) as caught:
            self.pair()
        self.assertRegex(str(caught.exception), "did not answer|without an answer")
        self.assertEqual((self.events, self.server.pairing_status()["open_links"]), ([], 0))

    def test_peer_credentials_are_read_in_kernel_order(self):
        left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        with left, right:
            self.assertEqual(svc.peer_credentials(left), (os.getpid(), os.geteuid(), os.getegid()))

    def test_a_slow_control_client(self):
        self.start()
        for payload in (b"", b"x" * 1100):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(60)
                client.connect(str(self.paths.control))
                if payload:
                    client.sendall(payload)
                try:
                    answer = client.recv(64)
                except ConnectionResetError:            # closed with bytes unread
                    answer = b""
                self.assertEqual(answer, b"")           # closed with no answer
        self.assertRegex(self.pair()[1], r"#pair=[0-9a-f]{32}")

    def test_a_malformed_request_is_closed_or_refused(self):
        self.start()
        self.assertEqual(svc.control_request(self.paths.control, {"op": "nope"}), {"error": "unknown operation"})
        self.assertIn("malformed", svc.control_request(self.paths.control, {"op": "pair", "caller": "lead:x"})["error"])
        self.assertEqual(self.events, [])

    def test_the_socket_path_is_taken(self):
        self.paths.state.mkdir(exist_ok=True)
        self.paths.control.write_text("not a socket")
        self.assertIn("not a socket", svc.control_path_problem(self.paths.control))
        self.assertIn("not a socket", svc.running_report(self.paths))
        self.assertTrue(self.paths.control.is_file())
        self.paths.control.unlink()
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as live:
            live.bind(str(self.paths.control))
            live.listen(1)
            self.assertIn("another dashboard", svc.control_path_problem(self.paths.control))
            self.assertTrue(self.paths.control.exists())
        self.assertIsNone(svc.control_path_problem(self.paths.control))     # now stale: removed
        self.assertFalse(os.path.lexists(self.paths.control))

    def test_a_taken_path_serves_without_pairing(self):
        self.paths.control.write_text("")
        out = io.StringIO()
        self.assertIsNone(svc.control_opener(self.paths, out)(object()))
        self.assertIn("serving without pairing", out.getvalue())
        self.assertEqual(self.paths.control.read_text(), "")

    def test_a_long_socket_path(self):
        deep = svc.Paths(state=Path("/tmp") / ("d" * 120), unit_dir=Path("/tmp"), slug="r", workdir=Path("/tmp"))
        self.assertIn("longer than the 107", svc.control_path_problem(deep.control))
        with self.assertRaises(svc.ServiceRefused) as caught:
            svc.pair(deep, svc.Caller(), out=io.StringIO())
        self.assertIn("longer than 107", str(caught.exception))

    def test_a_stop_removes_the_socket_and_keeps_a_replacement(self):
        control = svc.ControlServer(self.paths.control, lambda request, pid: {})
        close = control.open()
        close()
        self.assertFalse(os.path.lexists(self.paths.control))
        close = svc.ControlServer(self.paths.control, lambda request, pid: {}).open()
        self.paths.control.unlink()
        self.paths.control.write_text("someone else's")
        close()
        self.assertTrue(self.paths.control.is_file())


if __name__ == "__main__":
    unittest.main()
