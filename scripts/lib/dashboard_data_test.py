#!/usr/bin/env python3
"""Medium tests of the live-data path: a real server on 127.0.0.1 port 0, the real
loaders, and a stub `bd` that records its argv, environment and directory. No Dolt, no
real `bd`, no fixed sleeps: the refresher is stepped by hand, or waited on by event with
a bounded timeout."""
from __future__ import annotations

import gzip, json, os, socket, subprocess, sys, tempfile, threading, unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_cache as cache
import dashboard_security as sec
import dashboard_server as ds
import dashboard_sources as sources

ADDRESS = "someone" + "@" + "example.com"
STDERR_TEXT = "dial tcp 127.0.0.1:3307: connection refused (/home/jome/.beads, user" + "@" + "example.org)"
STUB = f"""#!{sys.executable}
import json, os, sys
stub = os.environ["STUB_DIR"]
mode = open(os.path.join(stub, "mode")).read().strip()
with open(os.path.join(stub, "calls.jsonl"), "a") as log:
    log.write(json.dumps({{"argv": sys.argv[1:], "auto_start": os.environ.get("BEADS_DOLT_AUTO_START"),
                          "optional_locks": os.environ.get("GIT_OPTIONAL_LOCKS"), "cwd": os.getcwd()}}) + "\\n")
if mode == "down":
    sys.stderr.write({STDERR_TEXT!r})
    sys.exit(1)
words = sys.argv[1:]
answer = "list" if "list" in words else "ready" if "ready" in words else "cycles"
print(open(os.path.join(stub, answer + ".json")).read())
"""
LOOPBACK = sec.check_bind("127.0.0.1")


def bead(identifier, **extra):
    return {"id": identifier, "title": f"Title of {identifier}", "status": "open", "priority": 2,
            "issue_type": "task", "labels": ["openspec:change:demo"], "owner": ADDRESS,
            "created_by": ADDRESS, "assignee": "Nogging Orchestrator", "description": "long description",
            "notes": f"ask {ADDRESS} about it", "created_at": "2026-10-01T10:00:00Z", **extra}


class Live(unittest.TestCase):
    """One stub `bd`, one scratch home and one server per test."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.stub_dir, self.home, self.static = root / "stub", root / "home", root / "static"
        for directory in (self.stub_dir, self.home, self.static):
            directory.mkdir()
        (self.static / "index.html").write_text("<!doctype html><title>x</title>")
        self.bd = self.stub_dir / "bd"
        self.bd.write_text(STUB)
        self.bd.chmod(0o755)
        self.set_mode("ok")
        self.answer("list", [bead("SPEC-aaaa"), bead("SPEC-bbbb", status="closed", labels=[]),
                             bead("SPEC-cccc", labels=["discovery"])])
        self.answer("ready", [{"id": "SPEC-aaaa"}])
        self.answer("cycles", [])
        os.environ["STUB_DIR"] = str(self.stub_dir)
        self.addCleanup(os.environ.pop, "STUB_DIR", None)

    def set_mode(self, mode):
        (self.stub_dir / "mode").write_text(mode)

    def answer(self, name, value):
        (self.stub_dir / f"{name}.json").write_text(json.dumps(value))

    def calls(self):
        path = self.stub_dir / "calls.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def start(self, readers=None, **options):
        readers = readers if readers is not None else {"beads": lambda: sources.read_beads(str(self.bd), self.home)}
        self.server = ds.DashboardServer(LOOPBACK, 0, assets=ds.load_assets(self.static), readers=readers, **options)
        thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.addCleanup(self.server.refresher.stop)
        return self.server.refresher

    def get(self, path, gzipped=False):
        host = f"127.0.0.1:{self.server.port}"
        encoding = "Accept-Encoding: gzip\r\n" if gzipped else ""
        with socket.create_connection(("127.0.0.1", self.server.port), timeout=5) as sock:
            sock.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\n{encoding}\r\n".encode())
            data = b""
            while chunk := sock.recv(65536):
                data += chunk
        head, _, body = data.partition(b"\r\n\r\n")
        status = int(head.split()[1])
        if b"content-encoding: gzip" in head.lower():
            body = gzip.decompress(body)
        return status, json.loads(body) if body.startswith(b"{") else body

    def load(self, refresher, rounds=1):
        for _ in range(rounds):
            refresher.step()


class FirstLoad(Live):
    def test_the_first_page_load_shows_loading_and_then_the_data(self):
        refresher = self.start()
        status, shell = self.get("/")
        self.assertEqual(status, 200)                       # the socket is open before any source loaded
        status, doc = self.get("/api/v1/freshness")
        self.assertEqual((status, doc["data"]["beads"]["state"]), (200, "loading"))
        status, doc = self.get("/api/v1/beads")
        self.assertEqual((status, doc["data"], doc["sources"]["beads"]["state"]), (200, {"beads": []}, "loading"))
        self.load(refresher)
        status, doc = self.get("/api/v1/beads")
        self.assertEqual(doc["sources"]["beads"]["state"], "fresh")
        self.assertEqual([item["id"] for item in doc["data"]["beads"]], ["SPEC-aaaa", "SPEC-bbbb", "SPEC-cccc"])
        self.assertEqual(doc["schema"], "nogg.dashboard.beads/v1")
        self.assertEqual(doc["sources"]["beads"]["generation"], 1)

    def test_the_list_payload_carries_no_description_and_no_notes(self):
        self.load(self.start())
        _, doc = self.get("/api/v1/beads")
        text = json.dumps(doc)
        for needle in ("description", "notes", "close_reason", "long description", "ask "):
            self.assertNotIn(needle, text)

    def test_the_changes_route_lists_a_bead_without_a_change(self):
        self.load(self.start())
        _, doc = self.get("/api/v1/changes")
        self.assertEqual([item["change"] for item in doc["data"]["changes"]], ["demo", None])
        self.assertEqual(doc["data"]["changes"][1]["total"], 2)

    def test_a_gzip_client_gets_the_same_document(self):
        self.load(self.start())
        self.assertEqual(self.get("/api/v1/beads", gzipped=True), self.get("/api/v1/beads"))

    def test_the_freshness_route_is_the_sources_block_only(self):
        refresher = self.start({"beads": lambda: sources.read_beads(str(self.bd), self.home),
                                "tests": lambda: (_ for _ in ()).throw(cache.Absent())})
        self.load(refresher, 2)
        _, doc = self.get("/api/v1/freshness")
        self.assertEqual(doc["data"], doc["sources"])
        self.assertEqual({name: item["state"] for name, item in doc["data"].items()},
                         {"beads": "fresh", "tests": "absent"})


class ReadOnly(Live):
    def test_beads_are_read_only(self):
        self.load(self.start())
        calls = self.calls()
        self.assertEqual(len(calls), 3)
        for call in calls:
            self.assertEqual(call["argv"][:2], ["--readonly", "--sandbox"])
            self.assertEqual((call["auto_start"], call["optional_locks"]), ("0", "0"))
            self.assertEqual(Path(call["cwd"]).resolve(), self.home.resolve())
        self.assertEqual([call["argv"][2] for call in calls], ["list", "ready", "dep"])

    def test_a_request_spawns_nothing(self):
        refresher = self.start()
        self.load(refresher)
        before = len(self.calls())
        routes = ["/", "/api/v1/auth", "/api/v1/freshness", "/api/v1/beads", "/api/v1/changes",
                  "/api/v1/beads/SPEC-aaaa", "/api/v1/summary", "/api/v1/graph", "/nothing"]
        spawned = []
        original = subprocess.Popen.__init__
        with mock.patch.object(subprocess.Popen, "__init__",
                               lambda this, *args, **kwargs: (spawned.append(args), original(this, *args, **kwargs))[1]):
            for number in range(100):
                self.get(routes[number % len(routes)])
        self.assertEqual(spawned, [])
        self.assertEqual(len(self.calls()), before)

    def test_no_snapshot_lands_on_disk(self):
        refresher = self.start()
        before = sorted(self.home.rglob("*"))
        self.load(refresher, 3)
        self.get("/api/v1/beads")
        self.assertEqual(sorted(self.home.rglob("*")), before)
        self.assertEqual(sorted(path.name for path in self.static.iterdir()), ["index.html"])

    def test_the_stub_is_not_asked_to_start_dolt(self):
        refresher = self.start()
        self.load(refresher)
        words = {word for call in self.calls() for word in call["argv"]}
        self.assertFalse(words & {"dolt", "doctor", "start", "stop", "restart", "init", "create", "update", "close"})


class Failures(Live):
    def test_dolt_is_down_the_source_is_unavailable_and_nothing_starts(self):
        refresher = self.start()
        self.set_mode("down")
        self.load(refresher)
        _, doc = self.get("/api/v1/beads")
        self.assertEqual(doc["sources"]["beads"], {"state": "unavailable", "as_of": None, "generation": 0,
                                                   "reason": "dolt_unreachable"})
        self.assertEqual(doc["data"], {"beads": []})
        self.assertEqual([call["argv"][2] for call in self.calls()], ["list"])     # the first failure stops the pass

    def test_a_source_error_shows_the_class_and_never_the_stderr(self):
        refresher = self.start()
        self.set_mode("down")
        self.load(refresher)
        for path in ("/api/v1/freshness", "/api/v1/beads", "/api/v1/changes"):
            _, doc = self.get(path)
            text = json.dumps(doc)
            for leaked in ("connection refused", "3307", "jome", "example.org", "dial tcp"):
                self.assertNotIn(leaked, text)

    def test_dolt_goes_down_after_a_good_load_and_the_last_data_stays_stale(self):
        refresher = self.start()
        self.load(refresher)
        self.set_mode("down")
        refresher.cells["beads"].due = 0
        self.load(refresher)
        _, doc = self.get("/api/v1/beads")
        self.assertEqual((doc["sources"]["beads"]["state"], doc["sources"]["beads"]["reason"]), ("stale", "dolt_unreachable"))
        self.assertEqual(len(doc["data"]["beads"]), 3)
        self.set_mode("ok")
        refresher.cells["beads"].due = 0
        self.load(refresher)
        _, doc = self.get("/api/v1/beads")
        self.assertEqual(doc["sources"]["beads"]["state"], "fresh")
        self.assertNotIn("reason", doc["sources"]["beads"])

    def test_a_repository_without_bd_reports_it_and_still_serves(self):
        refresher = self.start({"beads": lambda: sources.read_beads("bd-is-not-installed-here", self.home)})
        self.load(refresher)
        status, doc = self.get("/api/v1/beads")
        self.assertEqual((status, doc["sources"]["beads"]["state"], doc["sources"]["beads"]["reason"]),
                         (200, "unavailable", "bd_absent"))
        self.assertEqual(self.get("/")[0], 200)

    def test_one_failing_source_leaves_the_others_fresh(self):
        def broken():
            raise sources.SourceError("bd_error")
        refresher = self.start({"beads": lambda: sources.read_beads(str(self.bd), self.home), "tokens": broken})
        self.load(refresher, 2)
        _, doc = self.get("/api/v1/freshness")
        self.assertEqual((doc["data"]["beads"]["state"], doc["data"]["tokens"]["state"]), ("fresh", "unavailable"))


class Allowed(Live):
    def test_an_owner_address_reaches_no_response(self):
        refresher = self.start()
        self.load(refresher)
        for path in ("/api/v1/freshness", "/api/v1/beads", "/api/v1/changes"):
            for gzipped in (False, True):
                _, doc = self.get(path, gzipped)
                text = json.dumps(doc)
                self.assertNotIn(ADDRESS, text)
                self.assertNotIn("Nogging Orchestrator", text)
                for private in ("owner", "created_by", "assignee"):
                    self.assertNotIn(f'"{private}"', text)
        # The address in a note is replaced where the note is held for the detail view.
        notes = refresher.snapshot("beads")["beads"][0]["notes"]
        self.assertEqual(notes, "ask [address] about it")

    def test_the_session_snapshot_holds_only_allow_listed_fields(self):
        record = {"name": "s1", "agent": "claude", "state": "ended", "started_at": "2026-11-01T10:00:00Z",
                  "command": ["claude", "--token", "x"], "launch_prompt": "secret prompt", "owner": ADDRESS,
                  "exit_reason": f"first {ADDRESS}\nsecond"}
        refresher = self.start({"sessions": lambda: sources.read_sessions([record])})
        self.load(refresher)
        snapshot = refresher.snapshot("sessions")
        self.assertEqual(sorted(snapshot["sessions"][0]), sorted(sources.model.SESSION_FIELDS))
        self.assertEqual(snapshot["sessions"][0]["exit_reason"], "first [address]")
        _, doc = self.get("/api/v1/freshness")
        self.assertNotIn(ADDRESS, json.dumps(doc))


class Concurrency(Live):
    def test_many_clients_never_run_two_sources_at_once(self):
        running, peak, lock = [0], [0], threading.Lock()

        def reader(name):
            def read():
                with lock:
                    running[0] += 1
                    peak[0] = max(peak[0], running[0])
                try:
                    return sources.read_beads(str(self.bd), self.home) if name == "beads" else {"name": name}
                finally:
                    with lock:
                        running[0] -= 1
            return read
        refresher = self.start({name: reader(name) for name in ("beads", "sessions", "tests", "git", "tokens")})
        refresher.start()
        errors = []

        def client():
            try:
                for _ in range(10):
                    self.assertEqual(self.get("/api/v1/freshness")[0], 200)
                    self.assertEqual(self.get("/api/v1/beads")[0], 200)
            except Exception as exc:                      # surfaced below, on the test thread
                errors.append(exc)
        clients = [threading.Thread(target=client) for _ in range(10)]
        for thread in clients:
            thread.start()
        for thread in clients:
            thread.join(30)
        self.assertEqual(errors, [])
        self.assertTrue(refresher.wait_until(
            lambda status: all(item["state"] == "fresh" for item in status.values()), 30))
        self.assertEqual(peak[0], 1)
        self.assertEqual(len(self.calls()), 3)           # one pass of bd, however many phones asked


if __name__ == "__main__":
    unittest.main()
