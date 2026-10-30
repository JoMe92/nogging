#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHONPATH="$ROOT/scripts/lib${PYTHONPATH:+:$PYTHONPATH}" python3 - <<'PY'
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

import loop_cli
import loop_state


class LoopCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.main = self.tmp / "repo"
        self.main.mkdir()
        self.defs = self.main / ".nogging/loops.json"

    def args(self, action, **kw):
        values = dict(loop_command=action, name="night-work", json=False,
                      limit=20, prompt="Review the queue.", prompt_file=None,
                      every="30m", at=None, start=None, days=None, windows=None,
                      grace=None, mode="send", target="orchestrator", agent=None,
                      tier=None, model=None, effort=None, authority=None,
                      max_runtime=None, host=None, max_used_percent=None,
                      on_unknown=None)
        values.update(kw)
        return SimpleNamespace(**values)

    def invoke(self, action, **kw):
        return loop_cli.command(self.args(action, **kw), main_checkout=self.main,
                                definitions_path=self.defs, session_record=None)

    def test_add_approves_and_state_is_host_local(self):
        self.invoke("add")
        raw = json.loads(self.defs.read_text())
        self.assertEqual(raw["timezone"], loop_cli._host_timezone())
        self.assertEqual(raw["loops"]["night-work"]["run"]["mode"], "send")
        self.assertTrue((self.main / ".nogging/loops/night-work.md").exists())
        ledger = json.loads(loop_state.approvals_path(self.main).read_text())
        approval = ledger["loops"]["night-work"]
        self.assertEqual(len(approval["sha256"]), 64)
        self.assertNotIn("@", approval["user"])
        self.assertTrue(loop_state.approval_status(
            self.main, self.defs, __import__("loop_config").load(self.defs), "night-work")[0])

    def test_edited_prompt_requires_reapproval(self):
        self.invoke("add")
        prompt = self.main / ".nogging/loops/night-work.md"
        prompt.write_text("A changed standing instruction.")
        config = __import__("loop_config").load(self.defs)
        self.assertFalse(loop_state.approval_status(self.main, self.defs, config, "night-work")[0])

    def test_mutations_refuse_non_orchestrator_sessions(self):
        with self.assertRaisesRegex(RuntimeError, "only the Orchestration Agent"):
            loop_cli.command(self.args("add"), main_checkout=self.main,
                             definitions_path=self.defs,
                             session_record={"name": "lead", "role": "lead"})
        self.assertFalse(self.defs.exists())

    def test_pause_resume_remove_keep_run_history(self):
        self.invoke("add")
        history = self.main / ".nogging/state/loops/runs.jsonl"
        history.parent.mkdir(parents=True, exist_ok=True)
        history.write_text('{"loop":"night-work","event":"completed"}\n')
        self.invoke("pause")
        self.assertTrue(loop_state.read_state(self.main)["loops"]["night-work"]["paused"])
        self.invoke("resume")
        self.assertFalse(loop_state.read_state(self.main)["loops"]["night-work"]["paused"])
        self.invoke("remove")
        self.assertFalse((self.main / ".nogging/loops/night-work.md").exists())
        self.assertTrue(history.exists())

    def test_missing_run_log_is_empty_json(self):
        self.invoke("add")
        from contextlib import redirect_stdout
        from io import StringIO
        out = StringIO()
        with redirect_stdout(out):
            self.invoke("log", json=True)
        self.assertEqual(json.loads(out.getvalue())["runs"], [])


unittest.main()
PY
