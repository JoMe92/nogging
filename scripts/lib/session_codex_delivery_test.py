import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

MODULE = Path(__file__).with_name("session_codex_delivery.py")
spec = importlib.util.spec_from_file_location("session_codex_delivery", MODULE)
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)


def row(text, *, role="user", kind="response_item"):
    return json.dumps({"type": kind, "payload": {"type": "message", "role": role,
                      "content": [{"type": "input_text", "text": text}]}}).encode()


class ReceiptReaderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.path = Path(self.tmp.name) / "thread.jsonl"
        self.path.write_bytes(b'{"type":"session_meta","id":"thread-1","cwd":"/scratch"}\n')
        self.snap = reader.snapshot_source(self.path, "thread-1")

    def tearDown(self):
        self.tmp.cleanup()

    def append(self, data):
        with self.path.open("ab") as f:
            f.write(data)

    def read(self, msg="hello"):
        return reader.read_fresh_receipt(self.snap, msg)

    def test_incremental_exact_thread_user_only_and_unicode(self):
        self.append(row("historical") + b"\n" + row("hello", role="assistant") + b"\n")
        result, self.snap = self.read()
        self.assertEqual("unknown", result["status"])
        self.append(row("hello 🌱") + b"\n")
        result, self.snap = self.read("hello 🌱")
        self.assertEqual("receipt", result["status"])
        self.assertEqual("thread-1", result["thread_id"])
        self.assertIn("identity", result)

    def test_partial_final_line_at_snapshot_and_poll(self):
        self.path.write_bytes(self.path.read_bytes() + b'{"partial":')
        self.snap = reader.snapshot_source(self.path, "thread-1")
        self.append(b'"old"}\n')
        result, self.snap = self.read()
        self.assertEqual("unknown", result["status"])
        self.append(row("hello"))
        result, self.snap = self.read()
        self.assertEqual("unknown", result["status"])
        self.append(b"\n")
        result, self.snap = self.read()
        self.assertEqual("receipt", result["status"])

    def test_crlf_normalization_and_historical_match_excluded(self):
        self.append(row("old\r\nline") + b"\n")
        result, self.snap = self.read("old\nline")
        self.assertEqual("receipt", result["status"])

    def test_rotation_truncation_missing_and_scan_limits_are_unknown(self):
        replacement = self.path.with_suffix(".new")
        replacement.write_bytes(b"")
        replacement.replace(self.path)
        self.assertEqual("unknown", self.read()[0]["status"])
        self.snap = reader.snapshot_source(self.path, "thread-1")
        self.append(b"x" * 30)
        result, next_snap = reader.read_fresh_receipt(self.snap, "hello", poll_limit=8, operation_limit=16)
        self.assertEqual("unknown", result["status"])
        result, _ = reader.read_fresh_receipt(next_snap, "hello", poll_limit=8, operation_limit=16)
        self.assertEqual("unknown", result["status"])

    def test_persisted_source_is_opaque_and_rereads_the_unfinished_line(self):
        self.append(row("hello")[:20])        # an unfinished line at the snapshot
        self.snap = reader.snapshot_source(self.path, "thread-1")
        stored = reader.persistable_source(self.snap)
        self.assertEqual({"thread_id", "path", "device", "inode", "offset"}, set(stored))
        self.assertNotIn("hello", json.dumps(stored))
        self.append(row("hello")[20:] + b"\n")
        restored = reader.restore_snapshot(json.loads(json.dumps(stored)))
        result, _ = reader.read_fresh_receipt(restored, "hello")
        self.assertEqual("receipt", result["status"])
        for bad in (None, {}, {"thread_id": "t"}, "x"):
            self.assertIn("unknown", reader.restore_snapshot(bad))
        self.assertIsNone(reader.persistable_source({"unknown": "source unavailable"}))

    def test_unavailable_source_is_unknown(self):
        self.assertEqual("source unavailable", reader.snapshot_source(self.path / "missing", "thread")["unknown"])


class LastTurnTests(unittest.TestCase):
    def read(self, *lines):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "rollout.jsonl"
            path.write_text("\n".join(lines) + "\n")
            return reader.last_turn(path)

    @staticmethod
    def event(kind, **payload):
        return json.dumps({"type": "event_msg", "payload": {"type": kind, **payload}})

    def test_complete_turn_carries_its_message(self):
        turn = self.read(self.event("task_started"), self.event("task_complete", last_agent_message="PR open"))
        self.assertEqual(("idle", "task_complete", "PR open"), (turn["state"], turn["end"], turn["message"]))

    def test_abort_carries_its_reason_and_a_new_turn_resets_it(self):
        turn = self.read(self.event("task_started"), self.event("turn_aborted", reason="interrupted"))
        self.assertEqual(("idle", "aborted", "interrupted"), (turn["state"], turn["end"], turn["reason"]))
        turn = self.read(self.event("task_started"), self.event("turn_aborted", reason="x"), self.event("task_started"))
        self.assertEqual(("running", None, None), (turn["state"], turn["end"], turn["reason"]))

    def test_unknown_records_and_a_terminal_without_a_start_prove_nothing(self):
        turn = self.read(self.event("future_kind"), "garbage", self.event("task_complete", last_agent_message="x"))
        self.assertEqual("none", turn["state"])
        self.assertEqual("none", reader.last_turn("/nonexistent/rollout.jsonl")["state"])

    def test_non_text_message_is_dropped(self):
        turn = self.read(self.event("task_started"), self.event("task_complete", last_agent_message=7))
        self.assertIsNone(turn["message"])


if __name__ == "__main__":
    unittest.main()
