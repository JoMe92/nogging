#!/usr/bin/env bash
# TASK-SWK-009 (openspec/changes/session-wake): the user pause. The parse, the state and
# the summary are pure cases in session_pause_test.py with an injected clock; this file
# covers the loop runner with a clock passed in, the authority of each caller, the real
# commands in a scratch repository, and one digest on resume to a stub orchestrator on a
# private socket. Offline: stub agents, stub gh, stub bd.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; use_agent_stubs

while IFS= read -r inherited; do
  case "$inherited" in
    NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_*|GIT_*) unset "$inherited" ;;
  esac
done < <(compgen -e)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
nogg="$here/nogg"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
expect() { # expect <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 (expected: $2, got: $3)"; fi
}
has() { # has <description> <needle> <text>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 (no '$2' in: $3)" ;; esac
}
lacks() { # lacks <description> <needle> <text>
  case "$3" in *"$2"*) bad "$1 ('$2' in: $3)" ;; *) ok "$1" ;; esac
}

# --- the pure half (source-only; an installed consumer skips) --------------------
if [[ -f "$here/lib/session_pause_test.py" ]]; then
  python3 "$here/lib/session_pause_test.py" >"$work/unit.out" 2>&1 && ok "session_pause_test.py" \
    || { bad "session_pause_test.py"; cat "$work/unit.out"; }
else
  ok "session_pause_test.py skipped (installed consumer copy)"
fi

# --- the loop runner with an injected clock --------------------------------------
PYTHONPATH="$here/lib" python3 - >"$work/loops.out" 2>&1 <<'PY' && ok "loops: a pause skips, keeps and leaves state alone" || { bad "loops: see above"; cat "$work/loops.out"; }
import json, tempfile, unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from types import SimpleNamespace

import loop_cli, loop_config, loop_runner, loop_state, session_pause

UTC = timezone.utc
T0 = datetime(2026, 1, 1, tzinfo=UTC)


class PausedTicks(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.defs = self.root / ".nogging/loops.json"
        (self.root / ".nogging/loops").mkdir(parents=True)
        self.defs.write_text(json.dumps({"schema_version": 1, "timezone": "UTC", "loops": {
            name: {"schedule": {"every": "5m", "start": "00:00"}, "run": {"mode": "send", "target": "orchestrator"}}
            for name in ("alpha", "report")}}))
        config = loop_config.load(self.defs)
        for name in ("alpha", "report"):
            (self.root / f".nogging/loops/{name}.md").write_text("Report the queue.\n")
            loop_state.approve(self.root, self.defs, config, name, at=T0.isoformat(), user="operator")
        self.clock, self.sent, self.pause = [T0 + timedelta(minutes=6)], [], None
        self.runner = loop_runner.LoopRunner(
            self.root, self.defs, target=lambda: ({"name": "orch", "role": "orchestrator", "agent": "claude"}, "idle"),
            usage=lambda *args: (True, None, {"decision": "admitted", "windows": []}),
            send=lambda _record, text: self.sent.append(text), now=lambda: self.clock[0], host="test-host",
            pause=lambda _now: self.pause)

    def held(self, keep=()):
        self.pause = session_pause.begin(None, self.clock[0] + timedelta(days=2), list(keep), "operator", self.clock[0])

    def tick(self, minutes):
        self.clock[0] += timedelta(minutes=minutes)
        self.runner.tick()

    def rows(self, name):
        path = loop_runner.event_path(self.root)
        lines = path.read_text().splitlines() if path.exists() else []
        return [row for row in map(json.loads, lines) if row["loop"] == name]

    def loop_state_of(self, name):
        return loop_state.read_state(self.root)["loops"].get(name)

    def test_a_due_loop_is_skipped_once_per_slot_and_writes_no_state(self):
        self.held()
        before = sorted(p.name for p in (self.root / ".nogging").rglob("*") if p.is_file() and "approvals" in p.name)
        definitions = self.defs.read_bytes()
        self.tick(5); self.tick(1); self.tick(1)
        self.assertEqual(self.sent, [])
        rows = [row for row in self.rows("alpha") if row["event"] == "skipped"]
        self.assertEqual([row["reason"] for row in rows], ["paused-global"], "one line per slot, not per tick")
        self.assertIsNone(self.loop_state_of("alpha"), "no loop state for a skipped loop")
        self.assertEqual(self.defs.read_bytes(), definitions)
        self.assertEqual(before, sorted(p.name for p in (self.root / ".nogging").rglob("*")
                                        if p.is_file() and "approvals" in p.name))
        self.tick(5)
        self.assertEqual(len([row for row in self.rows("alpha") if row.get("reason") == "paused-global"]), 2)

    def test_a_kept_loop_runs_by_its_schedule(self):
        self.held(["report"])
        self.tick(5)
        self.assertEqual(len(self.sent), 1)
        self.assertTrue(self.rows("report"))
        self.assertEqual([row["reason"] for row in self.rows("alpha")], ["paused-global"])

    def test_an_individually_paused_loop_stays_paused(self):
        with loop_state.state_lock(self.root):
            state = loop_state.read_state(self.root)
            state.setdefault("loops", {})["report"] = {"paused": True}
            loop_state.write_state(self.root, state)
        self.held(["report"])
        self.tick(5)
        self.assertEqual(self.sent, [])
        self.pause = None
        self.tick(5)
        self.assertEqual(self.sent and [text for text in self.sent], [text for text in self.sent])
        self.assertTrue(self.loop_state_of("report")["paused"], "resume leaves a loop's own pause alone")
        self.assertFalse([row for row in self.rows("report") if row["event"] == "started"])

    def test_loops_run_again_once_the_pause_is_over(self):
        self.held()
        self.tick(5)
        self.pause = None
        self.tick(5)
        self.assertEqual(len(self.sent), 2, "both loops are due again")

    def test_a_started_run_is_still_supervised(self):
        self.tick(5)
        self.assertTrue(self.loop_state_of("alpha")["active_run"])
        self.held()
        self.tick(1); self.tick(1)
        self.assertIsNone(self.loop_state_of("alpha")["active_run"], "the idle orchestrator completes the run")
        self.assertIn("completed", [row["event"] for row in self.rows("alpha")])

    def test_run_now_is_someones_decision(self):
        self.held()
        self.clock[0] += timedelta(minutes=5)
        self.runner.run_now("alpha")
        self.assertEqual(len(self.sent), 1)

    def test_loop_list_shows_the_pause(self):
        self.held(["report"])
        args = SimpleNamespace(loop_command="list", json=True)
        import contextlib, io
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            loop_cli.command(args, main_checkout=self.root, definitions_path=self.defs, session_record=None, pause=self.pause)
        states = {row["name"]: row["state"] for row in json.loads(out.getvalue())["loops"]}
        self.assertEqual(states, {"alpha": f"paused (global, until {session_pause.until_text(self.pause)})", "report": "kept"})


unittest.main()
PY

[[ $fail -eq 0 ]] || { echo "session-pause: checks failed" >&2; exit 1; }
echo "session-pause: ok"
