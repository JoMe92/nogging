#!/usr/bin/env bash
# Loop definitions, prompt checks and validation (TASK-SCL-002).
# Drives scripts/lib/loop_config.py offline: no network, no systemd, no bd.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONPATH="$ROOT/scripts/lib${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path

import loop_config
from loop_config import (
    approval_hash, check_prompt, load, prompt_path, validate_hosts,
)

LOOP_KEYS = {"schedule", "run", "enabled", "host", "usage", "bogus"}


def send_run(**extra):
    return {"mode": "send", "target": "orchestrator", **extra}


def launch_run(**extra):
    return {"mode": "launch", "agent": "codex", "tier": "routine", **extra}


def loop_def(run=None, **fields):
    return {"schedule": {"every": "5h", "start": "02:07"},
            "run": run if run is not None else send_run(), **fields}


def full_config(**loops):
    return {"schema_version": 1, "timezone": "Europe/Berlin",
            "loops": {name: loop_def(**loop) for name, loop in loops.items()}}


class LoadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def load(self, config, name="loops.json"):
        path = self.tmp / name
        path.write_text(json.dumps(config), encoding="utf-8")
        return load(path)

    def test_valid_file_loads_with_defaults_and_no_state(self):
        path = self.tmp / "loops.json"
        path.write_text(json.dumps(full_config(
            night={},
            dep={"enabled": False, "host": "pi-a", "run": launch_run()})), encoding="utf-8")
        before = path.read_text()
        config = load(path)
        self.assertEqual(config["timezone"], "Europe/Berlin")
        self.assertEqual(config["scheduler"]["max_active_launch_runs"], 2)
        self.assertEqual(config["scheduler"]["suspend_after_failures"], 3)
        self.assertTrue(config["loops"]["night"]["enabled"])
        self.assertFalse(config["loops"]["dep"]["enabled"])
        self.assertEqual(config["loops"]["dep"]["run"]["authority"], "restricted")
        self.assertEqual(config["loops"]["dep"]["run"]["max_runtime"], "1h")
        self.assertEqual(before, path.read_text())   # no state written back

    def test_missing_file_means_no_loops(self):
        self.assertIsNone(load(self.tmp / "absent.json"))

    def test_missing_or_invalid_timezone_is_refused(self):
        with self.assertRaisesRegex(ValueError, "timezone"):
            self.load({"schema_version": 1, "loops": {}})
        with self.assertRaisesRegex(ValueError, "timezone"):
            self.load({"schema_version": 1, "timezone": "Mars/Olympus", "loops": {}})

    def test_wrong_schema_version_is_refused(self):
        with self.assertRaisesRegex(ValueError, "schema_version"):
            self.load({"schema_version": 2, "timezone": "UTC", "loops": {}})

    def test_unknown_keys_are_refused_at_every_level(self):
        with self.assertRaisesRegex(ValueError, "bogus"):
            self.load({**full_config(night={}), "bogus": 1})
        with self.assertRaisesRegex(ValueError, "bogus"):
            self.load(full_config(night={"bogus": 1}))
        with self.assertRaisesRegex(ValueError, "bogus"):
            self.load(full_config(night={"run": send_run(bogus=1)}))
        with self.assertRaisesRegex(ValueError, "bogus"):
            config = full_config(night={"usage": {"max_used_percent": 70}})
            config["loops"]["night"]["usage"]["bogus"] = 1
            self.load(config)
        with self.assertRaisesRegex(ValueError, "bogus"):
            self.load({**full_config(), "scheduler": {"bogus": 2}})

    def test_duplicate_json_key_is_refused(self):
        (self.tmp / "loops.json").write_text(
            '{"schema_version": 1, "timezone": "UTC", "loops": {}, "loops": {}}',
            encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            load(self.tmp / "loops.json")

    def test_duplicate_loop_names_through_duplicate_keys_are_refused(self):
        (self.tmp / "loops.json").write_text(
            json.dumps(full_config(night={}))[:-2] + ', "night": {"schedule": {}}}',
            encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            load(self.tmp / "loops.json")

    def test_loop_names_are_kebab_case_and_bounded(self):
        with self.assertRaisesRegex(ValueError, "night_shift"):
            self.load(full_config(night_shift={}))
        with self.assertRaisesRegex(ValueError, "loop name"):
            self.load(full_config(**{"x" * 41: {}}))

    def test_schedule_and_run_are_required_and_validated(self):
        with self.assertRaisesRegex(ValueError, "schedule"):
            self.load({"schema_version": 1, "timezone": "UTC",
                       "loops": {"night": {"run": send_run()}}})
        with self.assertRaisesRegex(ValueError, "run"):
            self.load({"schema_version": 1, "timezone": "UTC",
                       "loops": {"night": {"schedule": {"every": "1h"}}}})
        with self.assertRaisesRegex(ValueError, "schedule"):
            self.load(full_config(night={"schedule": {"every": "0h"}}))

    def test_scheduler_values_are_positive_integers(self):
        config = full_config()
        config["scheduler"] = {"suspend_after_failures": 0}
        with self.assertRaisesRegex(ValueError, "suspend_after_failures"):
            self.load(config)


class ModeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def load_run(self, run):
        path = self.tmp / "loops.json"
        path.write_text(json.dumps(full_config(night={"run": run})), encoding="utf-8")
        return load(path)["loops"]["night"]["run"]

    def test_send_targets_the_orchestrator_only(self):
        self.assertEqual(self.load_run(send_run())["target"], "orchestrator")
        with self.assertRaisesRegex(ValueError, "target"):
            self.load_run(send_run(target="lead"))

    def test_send_names_no_agent_tier_or_authority(self):
        for key, value in (("agent", "codex"), ("tier", "routine"),
                           ("authority", "trusted")):
            with self.assertRaisesRegex(ValueError, key):
                self.load_run(send_run(**{key: value}))

    def test_launch_requires_agent_and_tier(self):
        with self.assertRaisesRegex(ValueError, "agent"):
            self.load_run({"mode": "launch", "tier": "routine"})
        with self.assertRaisesRegex(ValueError, "tier"):
            self.load_run({"mode": "launch", "agent": "codex"})

    def test_launch_authority_is_restricted_trusted_only(self):
        self.assertEqual(self.load_run(launch_run())["authority"], "restricted")
        self.assertEqual(self.load_run(launch_run(authority="trusted"))["authority"],
                         "trusted")
        with self.assertRaisesRegex(ValueError, "authority"):
            self.load_run(launch_run(authority="full-access"))

    def test_launch_refuses_the_orchestrator_profile_and_prompts(self):
        for key, value in (("profile", "orchestrator"), ("prompt", "autonomous"),
                           ("prompt", "orchestrator")):
            with self.assertRaisesRegex(ValueError, key):
                self.load_run(launch_run(**{key: value}))

    def test_max_runtime_is_bounded(self):
        self.assertEqual(self.load_run(launch_run(max_runtime="45m"))["max_runtime"],
                         "45m")
        self.assertEqual(self.load_run(send_run(max_runtime="12h"))["max_runtime"],
                         "12h")
        for bad in ("4m", "13h", "7201m", "1x", ""):
            with self.assertRaisesRegex(ValueError, "max_runtime"):
                self.load_run(launch_run(max_runtime=bad))


class HostTests(unittest.TestCase):
    def test_multi_machine_requires_a_host_on_enabled_loops(self):
        config = full_config(night={"host": "pi-a"}, off={"enabled": False})
        validate_hosts(config, True)   # a disabled loop may omit host
        config["loops"]["bare"] = loop_def()
        with self.assertRaisesRegex(ValueError, "bare"):
            validate_hosts(config, True)

    def test_single_machine_host_is_optional_but_allowed(self):
        config = full_config(night={})
        validate_hosts(config, False)
        config["loops"]["night"]["host"] = "pi-a"
        validate_hosts(config, False)


class PromptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        (self.tmp / "loops").mkdir()
        self.defs = self.tmp / "loops.json"
        self.defs.write_text("{}", encoding="utf-8")

    def prompt(self, text, name="night"):
        path = prompt_path(self.defs, name)
        path.write_text(text, encoding="utf-8")
        return path

    def test_path_lives_beside_the_definitions_file(self):
        self.assertEqual(prompt_path(self.defs, "night"),
                         self.tmp / "loops" / "night.md")

    def test_missing_empty_and_oversized_prompts_are_errors(self):
        with self.assertRaisesRegex(ValueError, r"loops[/\\]night\.md"):
            check_prompt(prompt_path(self.defs, "night"))
        with self.assertRaisesRegex(ValueError, "empty"):
            check_prompt(self.prompt(""))
        with self.assertRaisesRegex(ValueError, "16 KiB"):
            check_prompt(self.prompt("x" * (16 * 1024 + 1)))
        path = prompt_path(self.defs, "night")
        path.write_bytes(b"\xff\xfe bad")
        with self.assertRaisesRegex(ValueError, "UTF-8"):
            check_prompt(path)
        with self.assertRaisesRegex(ValueError, "NUL"):
            check_prompt(self.prompt("ok\0text"))

    def test_email_is_rejected_with_file_and_line(self):
        with self.assertRaisesRegex(ValueError, "night.md.*line 3.*email"):
            check_prompt(self.prompt("one\ntwo\nreach me at ops@example.com\n"))

    def test_set_secret_value_is_rejected_without_echoing_it(self):
        secret = "sup3rs3cretvalue"
        os.environ["NOGG_TEST_LOOP_SECRET"] = secret
        try:
            with self.assertRaises(ValueError) as caught:
                check_prompt(self.prompt(f"use {secret} today"))
            self.assertNotIn(secret, str(caught.exception))
            self.assertIn("secret", str(caught.exception))
        finally:
            del os.environ["NOGG_TEST_LOOP_SECRET"]

    def test_secret_assignment_is_rejected_without_echoing_it(self):
        value = "hunter2-password"
        with self.assertRaises(ValueError) as caught:
            check_prompt(self.prompt(f'run with -c api_key="{value}"'))
        self.assertNotIn(value, str(caught.exception))
        self.assertIn("line 1", str(caught.exception))

    def test_token_shapes_are_rejected_without_echoing_them(self):
        tokens = [
            "ghp_" + "A" * 36,
            "github_pat_" + "b" * 30,
            "sk-ant-api03-" + "c" * 30,
            "sk-" + "d" * 25,
            "AKIA" + "E" * 16,
            "xoxb-" + "f" * 20,
        ]
        for token in tokens:
            with self.assertRaises(ValueError) as caught:
                check_prompt(self.prompt(f"token {token}"))
            message = str(caught.exception)
            self.assertNotIn(token, message)
            self.assertRegex(message.lower(), r"token|key")
        with self.assertRaisesRegex(ValueError, "private.key"):
            check_prompt(self.prompt("-----BEGIN RSA PRIVATE KEY-----"))

    def test_clean_prompt_passes(self):
        check_prompt(self.prompt("# Night loop\n\nRun the checks and report.\n"))


class HashTests(unittest.TestCase):
    def test_hash_is_canonical_and_covers_timezone_prompt_and_definition(self):
        loop = loop_def()
        base = {"timezone": "UTC", "loop": loop, "prompt": b"prompt\n"}
        first = approval_hash(**base)
        self.assertEqual(first, approval_hash(**base))
        self.assertEqual(first, hashlib.sha256(json.dumps(
            {"timezone": "UTC", "loop": loop, "prompt": list(b"prompt\n")},
            sort_keys=True, separators=(",", ":")).encode()).hexdigest())
        self.assertNotEqual(first, approval_hash(
            prompt=b"prompt\n", loop=loop_def(run=launch_run()), timezone="UTC"))
        self.assertNotEqual(first, approval_hash(prompt=b"other\n", loop=loop,
                                                 timezone="UTC"))
        self.assertNotEqual(first, approval_hash(prompt=b"prompt\n", loop=loop,
                                                 timezone="Europe/Berlin"))


if __name__ == "__main__":
    unittest.main()
PY
