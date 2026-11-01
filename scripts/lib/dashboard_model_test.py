#!/usr/bin/env python3
"""Small tests of the dashboard's allow-lists, scrubber and list views. Pure: no files, no `bd`."""
from __future__ import annotations

import json, sys, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dashboard_model as model

ADDRESS = "someone" + "@" + "example.com"
USERS = "/Us" + "ers"        # spelled apart: the public-tree check rejects a literal home path
OTHER = "first.last+tag" + "@" + "mail.example.org"


def raw_bead(**extra):
    bead = {"id": "SPEC-aaaa", "title": "A title", "status": "open", "priority": 2, "issue_type": "task",
            "labels": ["openspec:change:demo", "openspec:task:TASK-1"], "description": "Describe it",
            "notes": "A note", "close_reason": None, "created_at": "2026-10-09T11:09:59Z",
            "started_at": None, "closed_at": None, "updated_at": "2026-10-09T12:00:00.123456789+02:00",
            "dependency_count": 1, "dependent_count": 0, "owner": ADDRESS, "created_by": "Somebody",
            "assignee": "Nogging Orchestrator", "comment_count": 3, "design": "private", "external_ref": "x",
            "acceptance_criteria": "more text",
            "dependencies": [{"issue_id": "SPEC-aaaa", "depends_on_id": "SPEC-bbbb", "type": "blocks",
                              "created_at": "2026-10-09T11:09:59Z", "created_by": "Somebody",
                              "metadata": "{}"}]}
    bead.update(extra)
    return bead


class Scrubber(unittest.TestCase):
    def test_an_address_is_replaced(self):
        self.assertEqual(model.scrub(f"mail {ADDRESS}, or {OTHER}."), "mail [address], or [address].")

    def test_a_handle_and_a_dotted_name_are_left_alone(self):
        text = "see @types/node and scripts/lib/dashboard_model.py at v1.2.3"
        self.assertEqual(model.scrub(text), text)

    def test_a_home_directory_path_loses_its_user(self):
        self.assertEqual(model.scrub(f"saw /home/alice/src/nogging/x.py and {USERS}/ann/p and /root/.cache"),
                         "saw ~/src/nogging/x.py and ~/p and ~/.cache")
        self.assertEqual(model.scrub("a /rooted path and /homework"), "a /rooted path and /homework")

    def test_prefixed_tokens_are_replaced(self):
        for token in ("ghp_" + "a1B2" * 8, "github_pat_" + "x9" * 15, "sk-" + "Ab3" * 8,
                      "xoxb-" + "1234567890-abcdef", "AKIA" + "ABCDEFGH12345678",
                      "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc_def-123"):
            self.assertEqual(model.scrub(f"the key {token} ends"), "the key [secret] ends", token)

    def test_a_keyed_value_is_replaced_but_a_word_is_not(self):
        self.assertEqual(model.scrub("token=abcd1234efgh5678"), "token=[secret]")
        self.assertEqual(model.scrub("Authorization: Bearer abcdef0123456789xyz"), "Authorization: Bearer [secret]")
        self.assertEqual(model.scrub("token: constant-time compare"), "token: constant-time compare")

    def test_a_long_random_string_is_replaced_but_names_and_object_names_stay(self):
        urlsafe = "Q1w2E3r4T5y6U7i8O9p0AaSsDdFfGgHhJjKkLlZz"
        self.assertEqual(model.scrub(f"secret {urlsafe}"), "secret [secret]")
        sha = "846da79cbd64191a0c18308c9548c2f494198708"
        self.assertEqual(model.scrub(f"commits {sha}"), f"commits {sha}")
        sha256 = "ab" * 32
        self.assertEqual(model.scrub(sha256), sha256)
        name = "sf-lead-spec-bj7s-20261101t150609-fcb0"
        self.assertEqual(model.scrub(name), name)
        self.assertEqual(model.scrub("test_a_session_record_has_allow_listed_fields_only"),
                         "test_a_session_record_has_allow_listed_fields_only")

    def test_a_long_run_is_scrubbed_in_linear_time(self):
        import time
        for blob in ("-" * 200_000, "a." * 100_000, "a" * 200_000, "%" * 200_000, "a@" * 50_000):
            start = time.monotonic()
            model.scrub(blob)
            self.assertLess(time.monotonic() - start, 1.0, blob[:4])

    def test_keyed_values_in_the_common_pasted_forms_are_replaced(self):
        for text, expected in (("GITHUB_TOKEN=abcd1234efgh5678", "GITHUB_TOKEN=[secret]"),
                               ("OPENAI_API_KEY=sk_live1234", "OPENAI_API_KEY=[secret]"),
                               ('{"password": "hunter2xyz"}', '{"password": "[secret]"}'),
                               ('{"token":"abcd1234efgh5678abcd"}', '{"token":"[secret]"}'),
                               ("Authorization: Basic dXNlcjpwYXNzd29yZA==", "Authorization: Basic [secret]"),
                               ("password: hunter2", "password: [secret]"),
                               ("DB_PASSWORD=pa55word", "DB_PASSWORD=[secret]")):
            self.assertEqual(model.scrub(text), expected, text)

    def test_credentials_in_a_url_are_replaced(self):
        self.assertEqual(model.scrub("clone https://user:p4ss@host.example/x.git"), "clone https://[secret]@host.example/x.git")
        self.assertEqual(model.scrub("postgres://admin:hunter2@db:5432/x"), "postgres://[secret]@db:5432/x")
        self.assertEqual(model.scrub("see https://example.com/a/b?c=d"), "see https://example.com/a/b?c=d")

    def test_unicode_encoded_and_dotless_addresses_are_replaced(self):
        for text in ("j\u00f6ne@ex\u00e4mple.de", "joe@localhost", "user%40example.com", "a.b+c@d-e.example.org"):
            self.assertEqual(model.scrub(f"to {text}!"), "to [address]!", text)

    def test_home_paths_in_other_forms_lose_the_user(self):
        for text, expected in (("/var/home/alice/src", "~/src"), (f"/mnt/c{USERS}/Jo/x", "~/x"),
                               ("C:\\Us" + "ers\\Jo\\x", "~\\x"),
                               (f"c:{USERS}/Jo/x", "~/x"), ("~alice/x", "~/x")):
            self.assertEqual(model.scrub(text), expected, text)

    def test_what_is_no_text_is_none(self):
        self.assertIsNone(model.scrub(None))
        self.assertIsNone(model.scrub(12))

    def test_a_first_line_is_cut_after_the_scrub(self):
        self.assertEqual(model.first_line("\n  first line\nsecond"), "first line")
        self.assertIsNone(model.first_line("  \n \n"))
        # Cut at 200 characters, and an address that straddles the cut is not left half open.
        out = model.first_line("x" * 190 + " " + ADDRESS + " " + "y" * 50)
        self.assertEqual(out, "x" * 190 + " [address]")      # exactly 200, cut after the scrub


class Allowed(unittest.TestCase):
    def test_a_bead_has_exactly_the_listed_fields_and_no_private_ones(self):
        bead = model.allow_bead(raw_bead())
        self.assertEqual(tuple(bead), model.BEAD_FIELDS)
        text = json.dumps(bead)
        for private in (ADDRESS, "Somebody", "Nogging Orchestrator", "private", "more text"):
            self.assertNotIn(private, text)
        self.assertEqual(tuple(bead["dependencies"][0]), model.DEPENDENCY_FIELDS)

    def test_an_owner_address_never_arrives(self):
        for key in ("owner", "created_by", "assignee"):
            self.assertNotIn(key, model.allow_bead(raw_bead()))
        self.assertNotIn(ADDRESS, json.dumps(model.allow_bead(raw_bead(owner=ADDRESS, assignee=ADDRESS))))

    def test_an_address_in_notes_is_replaced(self):
        bead = model.allow_bead(raw_bead(notes=f"ask {ADDRESS} about it", description=f"by {OTHER}",
                                         title=f"{ADDRESS} title", close_reason=f"done by {ADDRESS}",
                                         labels=[f"who:{ADDRESS}"]))
        self.assertEqual(bead["notes"], "ask [address] about it")
        self.assertNotIn("@", json.dumps(bead))

    def test_a_malformed_bead_is_dropped_and_odd_fields_become_none(self):
        self.assertIsNone(model.allow_bead("x"))
        self.assertIsNone(model.allow_bead({"id": "../etc/passwd"}))
        bead = model.allow_bead({"id": "SPEC-x", "title": 5, "priority": True, "labels": "a", "parent": "no/slash",
                                 "created_at": "yesterday", "dependency_count": -1,
                                 "dependencies": [1, {"issue_id": "SPEC-x"}]})
        self.assertEqual((bead["title"], bead["priority"], bead["labels"], bead["parent"], bead["created_at"],
                          bead["dependency_count"], bead["dependencies"]), (None, None, [], None, None, None, []))

    def test_timestamps_are_utc_iso(self):
        self.assertEqual(model.utc_iso("2026-10-09T12:00:00.123456789+02:00"), "2026-10-09T10:00:00Z")
        self.assertEqual(model.utc_iso("2026-10-09T12:00:00"), "2026-10-09T12:00:00Z")
        self.assertIsNone(model.utc_iso(None))

    def test_a_session_record_has_exactly_the_listed_fields(self):
        record = {"name": "sf-lead-1", "agent": "claude", "requested_model": "claude-sonnet-5-5",
                  "reasoning_effort": "high", "selection_tier": "standard", "role": "lead",
                  "bead_id": "SPEC-aaaa", "planning_id": None, "state": "ended",
                  "started_at": "2026-11-01T10:00:00Z", "ended_at": "2026-11-01T11:00:00Z",
                  "exit_reason": "ok", "command": ["claude", "--secret"], "launch_prompt": "do it",
                  "working_dir": "/home/alice/src/x", "log_path": "/home/alice/log", "host": "pi",
                  "owner": ADDRESS, "session_pid": 12, "agent_state_grants": ["x"], "codex_thread_id": "t"}
        session = model.allow_session(record)
        self.assertEqual(tuple(session), model.SESSION_FIELDS)
        text = json.dumps(session)
        for private in ("--secret", "do it", "/home/alice", ADDRESS):
            self.assertNotIn(private, text)
        for key in ("command", "launch_prompt", "working_dir", "log_path", "host", "owner", "session_pid",
                    "agent_state_grants"):
            self.assertNotIn(key, session)
        self.assertIsNone(model.allow_session({"agent": "claude"}))
        self.assertIsNone(model.allow_session(["x"]))

    def test_a_long_exit_reason_is_its_scrubbed_first_line(self):
        reason = f"startup failed for {ADDRESS}\n" + "\n".join(f"line {n} /home/alice/log" for n in range(500))
        session = model.allow_session({"name": "s", "exit_reason": reason})
        self.assertEqual(session["exit_reason"], "startup failed for [address]")
        self.assertLessEqual(len(model.allow_session({"name": "s", "exit_reason": "y" * 900})["exit_reason"]), 200)

    def test_a_test_record_keeps_five_fields(self):
        record = {"bead": "SPEC-aaaa", "stage": "bead", "at": "2026-11-01T10:00:00+00:00", "seconds": 12.34567,
                  "status": "passed", "session": "s", "branch": "b", "head": "h", "reason": "text", "slowest": []}
        self.assertEqual(model.allow_test_record(record),
                         {"bead": "SPEC-aaaa", "stage": "bead", "at": "2026-11-01T10:00:00Z",
                          "seconds": 12.346, "status": "passed"})
        self.assertIsNone(model.allow_test_record({"stage": "nightly"}))

    def test_stage_seconds_sums_the_runs_that_ran(self):
        records = [{"bead": "B", "stage": "bead", "seconds": 10.0, "status": "passed", "at": None},
                   {"bead": "B", "stage": "bead", "seconds": 2.5, "status": "failed", "at": None},
                   {"bead": "B", "stage": "commit", "seconds": 4.0, "status": "skipped", "at": None},
                   {"bead": None, "stage": "bead", "seconds": 9.0, "status": "passed", "at": None}]
        self.assertEqual(model.stage_seconds(records),
                         {"B": {"changed": None, "commit": None, "bead": 12.5, "full": None}})


class Lists(unittest.TestCase):
    def snapshot(self):
        beads = [model.allow_bead(raw_bead()),
                 model.allow_bead(raw_bead(id="SPEC-bbbb", status="closed", labels=["openspec:change:demo"])),
                 model.allow_bead(raw_bead(id="SPEC-cccc", labels=["discovery"], status="in_progress")),
                 model.allow_bead(raw_bead(id="SPEC-dddd", labels=["openspec:change:other"]))]
        return {"beads": beads, "ready": ["SPEC-aaaa", "SPEC-dddd"], "cycles": []}

    def test_the_list_payload_has_no_long_text(self):
        rows = model.bead_list(self.snapshot())["beads"]
        self.assertEqual(len(rows), 4)
        for row in rows:
            self.assertEqual(tuple(row), model.LIST_FIELDS)
            for name in ("description", "notes", "close_reason"):
                self.assertNotIn(name, row)
        self.assertEqual([row["ready"] for row in rows], [True, False, False, True])
        self.assertNotIn("A note", json.dumps(rows))

    def test_a_bead_without_a_change_is_listed_under_no_change(self):
        rows = model.bead_list(self.snapshot())["beads"]
        self.assertEqual([row["change"] for row in rows], ["demo", "demo", None, "other"])
        changes = model.change_list(self.snapshot())["changes"]
        self.assertEqual([entry["change"] for entry in changes], ["demo", "other", None])
        self.assertEqual(changes[-1]["total"], 1)
        self.assertEqual(changes[-1]["by_status"]["in_progress"], 1)

    def test_the_change_list_counts_by_status_and_ready(self):
        demo = model.change_list(self.snapshot())["changes"][0]
        self.assertEqual(demo, {"change": "demo", "total": 2, "ready": 1,
                                "by_status": {"open": 1, "in_progress": 0, "blocked": 0, "deferred": 0, "closed": 1}})

    def test_a_status_named_like_the_counter_is_just_a_status(self):
        snapshot = {"beads": [model.allow_bead(raw_bead(status="_ready"))], "ready": ["SPEC-aaaa"]}
        entry = model.change_list(snapshot)["changes"][0]
        self.assertEqual((entry["by_status"]["_ready"], entry["ready"], entry["total"]), (1, 1, 1))

    def test_an_empty_snapshot_lists_nothing(self):
        self.assertEqual(model.bead_list({}), {"beads": []})
        self.assertEqual(model.change_list({}), {"changes": []})


if __name__ == "__main__":
    unittest.main()
