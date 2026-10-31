"""Pure tests for the user-level Codex Stop hook helpers."""
import copy
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import session_hooks as hooks

OURS = {"type": "command", "command": hooks.HOOK_COMMAND, "timeout": hooks.HOOK_TIMEOUT_SECONDS}
FOREIGN = {"type": "command", "command": "echo foreign"}


class FakeServer:
    def __init__(self):
        self.calls = []

    def request(self, method, params):
        self.calls.append((method, params))
        return {"status": "ok"}


class MergeTests(unittest.TestCase):
    def test_the_command_is_inert_outside_a_session_and_names_no_path(self):
        self.assertTrue(hooks.HOOK_COMMAND.startswith('[ -z "${NOGG_SESSION_NAME:-}" ] || '))
        self.assertTrue(hooks.HOOK_COMMAND.endswith(" || exit 0"))
        self.assertNotIn("/home", hooks.HOOK_COMMAND)

    def test_merge_appends_and_leaves_other_entries(self):
        document = {"hooks": {"Stop": [{"hooks": [FOREIGN]}], "SessionStart": [{"hooks": [FOREIGN]}]}}
        before = copy.deepcopy(document)
        self.assertTrue(hooks.merge_stop(document))
        self.assertEqual(before["hooks"]["Stop"][0], document["hooks"]["Stop"][0])
        self.assertEqual(before["hooks"]["SessionStart"], document["hooks"]["SessionStart"])
        self.assertEqual({"hooks": [OURS]}, document["hooks"]["Stop"][1])

    def test_merge_of_an_empty_document_and_a_repeat(self):
        document = {}
        self.assertTrue(hooks.merge_stop(document))
        self.assertEqual({"hooks": {"Stop": [{"hooks": [OURS]}]}}, document)
        self.assertFalse(hooks.merge_stop(document))

    def test_merge_restores_an_edited_hook_in_place(self):
        edited = dict(OURS, command=hooks.HOOK_COMMAND + "; extra")
        document = {"hooks": {"Stop": [{"hooks": [edited]}, {"hooks": [FOREIGN]}]}}
        self.assertTrue(hooks.merge_stop(document))
        self.assertEqual([{"hooks": [OURS]}, {"hooks": [FOREIGN]}], document["hooks"]["Stop"])

    def test_remove_keeps_a_later_entrys_position(self):
        document = {"hooks": {"Stop": [{"hooks": [OURS]}, {"hooks": [FOREIGN]}]}}
        self.assertTrue(hooks.remove_stop(document))
        self.assertEqual([{"hooks": []}, {"hooks": [FOREIGN]}], document["hooks"]["Stop"])

    def test_remove_drops_a_trailing_entry_and_an_empty_key(self):
        document = {"hooks": {"Stop": [{"hooks": [OURS]}]}}
        self.assertTrue(hooks.remove_stop(document))
        self.assertEqual({"hooks": {}}, document)
        self.assertFalse(hooks.remove_stop(document))

    def test_remove_leaves_a_foreign_group_alone_and_refuses_a_shared_one(self):
        document = {"hooks": {"Stop": [{"hooks": [FOREIGN]}]}}
        self.assertFalse(hooks.remove_stop(document))
        self.assertEqual({"hooks": {"Stop": [{"hooks": [FOREIGN]}]}}, document)
        for handlers in ([OURS, FOREIGN], [OURS, OURS, FOREIGN], [OURS, FOREIGN, OURS]):
            shared = {"hooks": {"Stop": [{"hooks": list(handlers)}]}}
            with self.assertRaises(ValueError, msg=handlers):
                hooks.remove_stop(shared)
            self.assertEqual(handlers, shared["hooks"]["Stop"][0]["hooks"])

    def test_remove_takes_every_copy_when_nothing_follows(self):
        document = {"hooks": {"Stop": [{"hooks": [FOREIGN, OURS, OURS]}]}}
        self.assertTrue(hooks.remove_stop(document))
        self.assertEqual([{"hooks": [FOREIGN]}], document["hooks"]["Stop"])

    def test_unknown_shapes_are_refused(self):
        for document in ([], {"hooks": []}, {"hooks": {"Stop": {}}}, {"hooks": {"Stop": [1]}},
                         {"hooks": {"Stop": [{"hooks": {}}]}}):
            with self.assertRaises(ValueError, msg=document):
                hooks.merge_stop(document)


class FileTests(unittest.TestCase):
    def test_update_keeps_the_mode_and_leaves_no_temporary(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "hooks.json"
            path.write_text("{}")
            path.chmod(0o640)
            self.assertTrue(hooks.update_file(path, hooks.merge_stop))
            self.assertEqual(0o640, path.stat().st_mode & 0o777)
            self.assertEqual(["hooks.json"], os.listdir(tmp))

    def test_a_new_file_is_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "sub" / "hooks.json"
            hooks.update_file(path, hooks.merge_stop)
            self.assertEqual(0o600, path.stat().st_mode & 0o777)

    def test_no_change_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "hooks.json"
            text = json.dumps({"hooks": {"Stop": [{"hooks": [OURS]}]}})
            path.write_text(text)
            self.assertFalse(hooks.update_file(path, hooks.merge_stop))
            self.assertEqual(text, path.read_text())

    def test_symlink_and_junk_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            real, path = Path(tmp) / "real.json", Path(tmp) / "hooks.json"
            real.write_text("{}")
            path.symlink_to(real)
            with self.assertRaises(ValueError):
                hooks.update_file(path, hooks.merge_stop)
            path.unlink()
            path.write_text("junk")
            with self.assertRaises(ValueError):
                hooks.update_file(path, hooks.merge_stop)
            self.assertEqual("junk", path.read_text())


class ListingTests(unittest.TestCase):
    PATH = Path("/x/hooks.json")
    HOOK = {"key": "/x/hooks.json:stop:0:0", "eventName": "stop", "handlerType": "command", "async": False,
            "command": hooks.HOOK_COMMAND, "timeoutSec": hooks.HOOK_TIMEOUT_SECONDS, "source": "user",
            "sourcePath": "/x/hooks.json", "enabled": True, "currentHash": "sha256:a", "trustStatus": "trusted"}

    def test_only_a_user_stop_hook_from_this_file_is_ours(self):
        self.assertEqual(self.HOOK, hooks.find_hook([self.HOOK], self.PATH))
        for change in ({"source": "project"}, {"eventName": "sessionStart"}, {"sourcePath": "/y/hooks.json"},
                       {"command": "echo other"}):
            self.assertIsNone(hooks.find_hook([dict(self.HOOK, **change)], self.PATH), change)

    def test_a_failed_handshake_leaves_no_process(self):
        # It hangs without answering, so only the cleanup can end it.
        server = hooks.AppServer(["sleep", "60"], dict(os.environ), "/", timeout=0.2)
        with self.assertRaises(TimeoutError):
            server.__enter__()
        self.assertIsNotNone(server.process.poll())

    def test_only_the_exact_constant_is_exact(self):
        self.assertTrue(hooks.is_exact(self.HOOK))
        for change in ({"command": hooks.HOOK_COMMAND + "; x"}, {"timeoutSec": 1}, {"handlerType": "prompt"},
                       {"async": True}):
            self.assertFalse(hooks.is_exact(dict(self.HOOK, **change)), change)

    def test_states(self):
        self.assertEqual("trusted", hooks.hook_state(self.HOOK))
        self.assertEqual("untrusted", hooks.hook_state(dict(self.HOOK, trustStatus="untrusted")))
        self.assertEqual("modified", hooks.hook_state(dict(self.HOOK, trustStatus="modified")))
        self.assertEqual("modified", hooks.hook_state(dict(self.HOOK, command=hooks.HOOK_COMMAND + "; x")))
        self.assertEqual("untrusted", hooks.hook_state(dict(self.HOOK, enabled=False)))
        self.assertEqual("unknown", hooks.hook_state(dict(self.HOOK, trustStatus="managed")))
        self.assertEqual("unknown", hooks.hook_state(None))

    def test_trust_uses_codexs_own_api_with_a_quoted_key(self):
        server = FakeServer()
        hooks.trust(server, self.HOOK)
        hooks.untrust(server, self.HOOK)
        key_path = 'hooks.state."/x/hooks.json:stop:0:0"'
        self.assertEqual(("config/value/write", {"keyPath": key_path, "mergeStrategy": "upsert",
                                                 "value": {"trusted_hash": "sha256:a"}}), server.calls[0])
        self.assertEqual(("config/value/write", {"keyPath": key_path, "mergeStrategy": "replace", "value": None}),
                         server.calls[1])


if __name__ == "__main__":
    unittest.main()
