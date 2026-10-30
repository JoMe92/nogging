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
import json, os, stat, tempfile, unittest
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

    def test_a_pause_set_during_a_tick_holds_the_loops_still_to_come(self):
        self.runner.send = lambda _record, text: (self.sent.append(text), self.held())
        self.tick(5)
        self.assertEqual(len(self.sent), 1, "alpha ran, and report comes after the pause")
        self.assertEqual(self.rows("report"), [], "held, and its slot came before the pause began")

    def test_a_planted_run_log_stops_no_tick(self):
        self.held()
        path = loop_runner.event_path(self.root)
        path.parent.mkdir(parents=True, exist_ok=True)
        os.mkfifo(path)
        self.tick(5)
        self.assertTrue(stat.S_ISREG(path.lstat().st_mode), "the node is set aside")
        self.assertEqual([row["reason"] for row in self.rows("alpha")], ["paused-global"])

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
        self.assertEqual(len(self.sent), 1, "alpha runs again and report stays paused")
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

# --- who may hold the host -------------------------------------------------------
python3 - "$nogg" "$work/authority" <<'PY' && ok "authority: only an operator and the orchestrator, in the main checkout" || bad "authority: see above"
import json, pathlib, sys
from argparse import Namespace
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
m = SourceFileLoader("sf_swk009", sys.argv[1]).load_module()
state = pathlib.Path(sys.argv[2]); state.mkdir()
path, locks = state / "pause.json", state / "locks"

def run(record, root=None, **options):
    args = Namespace(**{"status": False, "json": False, "until": None, "days": "2", "keep_loop": None, **options})
    with patch.object(m, "pause_path", return_value=path), patch.object(m, "dispatch_dir", return_value=state), \
         patch.object(m, "ORCHESTRATOR_LOCKS", locks), patch.object(m, "session_records", return_value=[]), \
         patch.object(m, "calling_session_record", return_value=record), \
         patch.object(m, "ROOT", root or m.ORCHESTRATOR_HOME):
        m.pause_cmd(args)

for role in ("lead", "planning", "specialist:backend-engineer", "loop"):
    try:
        run({"name": "other", "role": role})
    except RuntimeError as exc:
        assert "refused inside supervised session other" in str(exc), exc
        assert "only the Orchestration Agent" in str(exc), exc
    else:
        raise AssertionError(f"{role} was not refused")
    assert not path.exists(), role
    run({"name": "other", "role": role}, status=True, days=None)          # the status reads anywhere
    assert not path.exists(), role

try:
    run(None, root=pathlib.Path("/elsewhere"))
except RuntimeError as exc:
    assert "main checkout" in str(exc), exc
else:
    raise AssertionError("a worktree was not refused")
assert not path.exists()

run({"name": "nogg-orchestrator-x", "role": "orchestrator"})
assert json.loads(path.read_text())["set_by"] == "nogg-orchestrator-x"
run(None, days="1")
assert json.loads(path.read_text())["set_by"] == "operator"

# Every session reads the status without a prompt, and no broader rule is given.
allow = m.merge_pause_status_permission({"permissions": {"allow": ["Read"]}})["permissions"]["allow"]
assert allow == ["Read", "Bash(./scripts/nogg pause --status:*)"], allow
assert m.merge_pause_status_permission({"permissions": {"allow": allow}})["permissions"]["allow"] == allow
source = pathlib.Path(sys.argv[1]).read_text()
assert 'base_settings = merge_pause_status_permission(base_settings)' in source

# A hold reaches the dispatcher whatever `enabled` says or leaves out.
held = {"until": "2026-11-03T00:00:00+00:00"}
for block in (None, {}, {"enabled": True}, {"enabled": False}):
    with patch.dict(m.CFG, {"session_dispatch": block}):
        assert m.dispatch_policy(held)["hold_sends"] is True, block
assert m.dispatch_wake_hold(held).startswith("paused until "), m.dispatch_wake_hold(held)
assert m.dispatch_policy()["hold_sends"] is False and m.dispatch_wake_hold() is None

# A loop run cannot pause or resume, and its deny rule leaves the status alone.
assert "Bash(./scripts/nogg pause --days:*)" in m.LOOP_DENY and "Bash(./scripts/nogg resume:*)" in m.LOOP_DENY
assert not [rule for rule in m.LOOP_DENY if "pause --status" in rule or rule.endswith("nogg pause:*)")]

# --- the end of a pause inside a pass ---------------------------------------------
import os, time
from datetime import datetime, timedelta, timezone
module = m.pause_module()
queue_path = state / "queue.json"
item = {"key": "s1|blocked|m", "kind": "blocked", "session": "s1", "reason": "r", "next": "bd show B1"}

def one_pass(gather=lambda: []):
    sent = []
    with patch.object(m, "pause_path", return_value=path), patch.object(m, "dispatch_dir", return_value=state), \
         patch.object(m, "ORCHESTRATOR_LOCKS", locks), patch.object(m, "session_records", side_effect=lambda *_a: gather()), \
         patch.object(m, "session_liveness", return_value=(set(), set())), \
         patch.object(m, "orchestrator_target", return_value=({"name": "orch"}, "idle")), \
         patch.object(m, "_orchestrator_usage", return_value=None), \
         patch.object(m, "orchestrator_send", side_effect=lambda _r, text: sent.append(text)):
        m._dispatch_pass(False, True)
    return sent

def seed(ends_in):
    moment = datetime.now(timezone.utc)
    old = (moment - timedelta(hours=2)).isoformat()
    module.write(path, {"schema": 1, "started_at": old, "until": (moment + timedelta(seconds=ends_in)).isoformat(),
                        "keep_loops": [], "set_by": "operator", "compacted_at": None})
    queue_path.write_text(json.dumps({"items": [{**item, "sticky": True, "created_at": old}]}))
    (state / "dispatch.jsonl").write_text(json.dumps({"time": (moment - timedelta(hours=1)).isoformat(), "action": "item",
                                                      "key": item["key"], "kind": "blocked", "outcome": "queued"}) + "\n")

# An end falling inside the gather holds this pass, so that the next one sends one digest.
seed(0.4)
assert one_pass(lambda: time.sleep(0.8) or []) == [] and path.exists(), "the pass read the pause twice"
sent = one_pass()
assert len(sent) == 1 and "resumed" in sent[0] and "items=2" in sent[0] and not path.exists(), sent

# A failed end costs no pass and no repeated digest: the state that stays holds delivery.
seed(-60)
with patch.object(module, "clear", side_effect=OSError("read-only file system")):
    for _ in range(3):
        assert one_pass() == []
assert len(json.loads(queue_path.read_text())["items"]) == 2 and path.exists()
with patch.object(m, "dispatch_dir", return_value=state), patch.object(m, "pause_path", return_value=path):
    warnings, notes = m.pause_diagnostics()
assert any("past its end" in line for line in warnings) and notes == [], (warnings, notes)
sent = one_pass()
assert len(sent) == 1 and not path.exists(), sent

# One wrong row and a planted audit generation stop neither a pass nor a tick.
seed(-60)
with (state / "dispatch.jsonl").open("a") as stream:
    stream.write(json.dumps({"time": datetime.now(timezone.utc).isoformat(), "action": "item", "key": "a",
                             "outcome": "queued", "kind": []}) + "\n")
os.mkfifo(state / "dispatch.jsonl.2")
sent = one_pass()
assert len(sent) == 1 and not path.exists(), sent
seed(-60)
(state / "dispatch.jsonl").unlink()
os.mkfifo(state / "dispatch.jsonl")
queue_path.unlink()
os.mkfifo(queue_path)
one_pass()
assert not path.exists() and queue_path.is_file() and (state / "dispatch.jsonl").is_file()
for name in ("dispatch.jsonl.2", "dispatch.jsonl.corrupt"):
    (state / name).unlink()

# A fault in the end never leaves `loop tick`.
seed(-60)
with patch.object(m, "pause_path", return_value=path), patch.object(m, "ORCHESTRATOR_LOCKS", locks), \
     patch.object(m, "_end_pause", side_effect=TypeError("a bad row")):
    m.end_due_pause()
assert path.exists()
PY

# --- the commands in a scratch repository ----------------------------------------
export HOME="$work/home"; mkdir -p "$HOME"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
root="$work/root"
pause_file="$root/.nogging/state/pause.json"
sessions="$root/.nogging/state/sessions"
dispatch_dir="$root/.nogging/state/dispatch"
queue_file="$dispatch_dir/queue.json"
mkdir -p "$sessions" "$root/.nogging/state/worktrees" "$root/scripts" "$work/bin"
ln -s "$here/lib" "$root/scripts/lib"
copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
export NOGGING_ROOT="$root"
sock="nogg-swk009-$$"
python3 - "$root/.nogging/config.json" "$sock" <<'PY'
import json, sys
path, sock = sys.argv[1:3]
config = json.load(open(path))
config.update(session_tmux_socket=sock, session_backend="tmux")
config.pop("session_dispatch", None)
config["usage_gate"] = {"enabled": False}
json.dump(config, open(path, "w"), indent=2)
PY
git init -q --bare -b develop "$work/upstream.git"
git -C "$root" init -q -b develop
printf '.nogging/\nscripts/\n' >"$root/.gitignore"
git -C "$root" add .gitignore; git -C "$root" commit -qm init
git -C "$root" remote add origin "$work/upstream.git"; git -C "$root" push -q -u origin develop
printf '#!/bin/sh\ncat "%s/gh.json"\n' "$work" >"$work/bin/gh"
printf '#!/bin/sh\ncat "%s/bd.json"\n' "$work" >"$work/bin/bd"
chmod +x "$work/bin/gh" "$work/bin/bd"; export PATH="$work/bin:$PATH"
echo '[]' >"$work/gh.json"
printf '[{"id":"B1","status":"in_progress"}]\n' >"$work/bd.json"

field() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$pause_file" "$2" 2>/dev/null || echo "$1"; }
status_field() { "$nogg" pause --status --json | python3 -c "import json,sys; print(json.load(sys.stdin).get(sys.argv[1]))" "$1"; }

"$nogg" loop add report --every 1d --mode send --prompt 'Report the queue.' >/dev/null
"$nogg" loop add scan --every 1d --mode send --prompt 'Scan the queue.' >/dev/null

expect "status: nothing is paused" "not paused" "$("$nogg" pause --status)"
expect "resume: not paused says so and exits 0" "nothing was paused" "$("$nogg" resume)"

# A pause for three days.
before=$(date +%s)
out=$("$nogg" pause --days 3)
after=$(date +%s)
has "pause: it prints the end" "paused until" "$out"
python3 - "$pause_file" "$before" "$after" <<'PY' && ok "pause: --days 3 ends 72 hours later, with every field" || bad "pause: wrong state: $(cat "$pause_file")"
import json, sys
from datetime import datetime
state = json.load(open(sys.argv[1]))
low, high = int(sys.argv[2]), int(sys.argv[3])
end = datetime.fromisoformat(state["until"]).timestamp()
assert low + 72 * 3600 - 1 <= end <= high + 72 * 3600 + 1, state
assert set(state) == {"schema", "started_at", "until", "keep_loops", "set_by", "compacted_at"}, state
assert state["keep_loops"] == [] and state["set_by"] == "operator" and state["compacted_at"] is None, state
PY
expect "status: json says paused" "True" "$(status_field paused)"
text=$("$nogg" pause --status)
for word in "paused until" "left" "started" "by operator" "kept loops: none"; do has "status: $word" "$word" "$text"; done

# It shows where a person looks.
has "doctor: a NOTE with the end" "NOTE  paused until" "$("$nogg" doctor 2>&1 || true)"
lacks "doctor: no FAIL for the pause" "FAIL  paused" "$("$nogg" doctor 2>&1 || true)"
has "session list: one line above the table" "PAUSED until" "$("$nogg" session list | head -3)"
has "inbox: it shows the pause and the held items" "PAUSED until" "$("$nogg" session inbox)"
has "inbox: it counts them" "0 item(s) held" "$("$nogg" session inbox)"
has "loop list: every loop is held" "paused (global, until" "$("$nogg" loop list)"

# A second pause replaces the first and keeps its start.
started=$(field - started_at)
"$nogg" pause --days 5 --keep-loop report --keep-loop scan --keep-loop report >/dev/null
expect "replace: the start stays" "$started" "$(field - started_at)"
expect "replace: the kept loops are new" "['report', 'scan']" "$(field - keep_loops)"
has "loop list: a kept loop" "kept" "$("$nogg" loop list)"

# A refused end or loop writes nothing.
stored=$(cat "$pause_file")
for args in "--days 61" "--days 0" "--days x" "--until 2020-01-01" "--until 2099-01-01" "--until tomorrow" "--days 1 --until 2026-12-01" "--days 1 --keep-loop ghost"; do
  # shellcheck disable=SC2086
  if out=$("$nogg" pause $args 2>&1); then bad "refused: pause $args exited 0"; else ok "refused: pause $args"; fi
done
has "refused: it names the unknown loop" "ghost" "$("$nogg" pause --days 1 --keep-loop ghost 2>&1 || true)"
if "$nogg" pause >/dev/null 2>&1; then bad "refused: no end at all"; else ok "refused: no end at all"; fi
expect "refused: nothing was written" "$stored" "$(cat "$pause_file")"

# A date alone is the start of that local day.
until=$(python3 -c "import datetime as d; print((d.date.today() + d.timedelta(days=4)).isoformat())")
"$nogg" pause --until "$until" >/dev/null
expect "until: a date is 00:00 local" "$until 00:00" "$(python3 - "$pause_file" <<'PY'
import json, sys
from datetime import datetime
print(datetime.fromisoformat(json.load(open(sys.argv[1]))["until"]).astimezone().strftime("%Y-%m-%d %H:%M"))
PY
)"

# A Lead is refused, and reads the status.
if out=$(NOGG_SESSION_NAME=lead-1 "$nogg" pause --days 2 2>&1); then bad "lead: pause exited 0"; else has "lead: pause is refused" "refusing nogg pause" "$out"; fi
if out=$(NOGG_SESSION_NAME=lead-1 "$nogg" resume 2>&1); then bad "lead: resume exited 0"; else has "lead: resume is refused" "refusing nogg resume" "$out"; fi
has "lead: the file is still there" "schema" "$(cat "$pause_file")"
has "lead: the status reads" "paused until" "$(NOGG_SESSION_NAME=lead-1 "$nogg" pause --status)"
sum=$(sha256sum "$pause_file")
NOGG_SESSION_NAME=lead-1 "$nogg" pause --status --json >/dev/null
expect "lead: the status changes nothing" "$sum" "$(sha256sum "$pause_file")"
if "$nogg" pause --status --days 2 >/dev/null 2>&1; then bad "status: refuses a write option"; else ok "status: refuses a write option"; fi

# A corrupt file does not block work, and a usable pause can replace it.
echo '{not json' >"$pause_file"
expect "corrupt: not paused" "False" "$(status_field paused)"
has "corrupt: the status says why" "not valid JSON" "$("$nogg" pause --status)"
has "corrupt: doctor warns, naming the file" "WARN  $pause_file" "$("$nogg" doctor 2>&1 || true)"
lacks "corrupt: session list is not paused" "PAUSED" "$("$nogg" session list)"
has "corrupt: resume removes it" "nothing was paused; removed" "$("$nogg" resume)"
[[ ! -e "$pause_file" ]] && ok "corrupt: the file is gone" || bad "corrupt: the file stayed"

# A pause ending by itself needs no dispatcher, and an uneventful one queues nothing.
write_pause() { # write_pause <minutes ago it ended> <days it ran>: a pause past its end
  python3 - "$pause_file" "$1" "$2" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
path, ended, days = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
end = datetime.now(timezone.utc) - timedelta(minutes=ended)
json.dump({"schema": 1, "started_at": (end - timedelta(days=days)).isoformat(), "until": end.isoformat(),
           "keep_loops": [], "set_by": "operator", "compacted_at": None}, open(path, "w"))
PY
}
write_pause 1 2
has "ended: the status says it is over" "the next pass clears it" "$("$nogg" pause --status)"
lacks "ended: session list does not call it paused" "PAUSED" "$("$nogg" session list)"
"$nogg" loop tick
[[ ! -e "$pause_file" ]] && ok "uneventful: a tick ends it without the dispatcher" || bad "uneventful: the tick left it"
[[ ! -e "$queue_file" ]] && ok "uneventful: nothing is queued" || bad "uneventful: $(cat "$queue_file")"

# A disabled dispatcher still clears a pause past its end, and prints only that it is off.
write_pause 1 2
expect "disabled: it says so" "session dispatch is disabled (session_dispatch.enabled is not true)" "$("$nogg" session dispatch --once)"
[[ ! -e "$pause_file" ]] && ok "disabled: the pause is gone" || bad "disabled: the pass left it"

# A directory planted at the path is reported, and resume still exits 0.
mkdir "$pause_file"
has "planted: resume says what to do" "by hand" "$("$nogg" resume)"
rmdir "$pause_file"

# With a live pause the tick ends nothing.
"$nogg" pause --days 1 >/dev/null; "$nogg" loop tick
[[ -e "$pause_file" ]] && ok "tick: a live pause stays" || bad "tick: it ended a live pause"
"$nogg" resume >/dev/null
[[ ! -e "$queue_file" ]] && ok "resume: an uneventful pause queues nothing" || bad "resume: $(cat "$queue_file")"

# --- a paused pass and one digest: a stub orchestrator on a private socket -------
if ! command -v tmux >/dev/null; then
  ok "integration skipped (tmux unavailable)"
else
  export TMUX_TMPDIR; TMUX_TMPDIR=$(mktemp -d /tmp/nogg-pause.XXXXXX)
  export NOGG_TEST_ARGS_DIR="$work/args"; mkdir -p "$NOGG_TEST_ARGS_DIR"
  trap 'tmux -L "$sock" kill-server 2>/dev/null || true; rm -rf "$work" "$TMUX_TMPDIR"' EXIT
  orch="nogg-orchestrator-root"
  python3 - "$root/.nogging/config.json" <<'PY'
import json, sys
config = json.load(open(sys.argv[1]))
config["session_dispatch"] = {"enabled": True}
json.dump(config, open(sys.argv[1], "w"), indent=2)
PY
  cat >"$work/runtime.py" <<'PY'
import sys
rule = "─" * 80
def paint():
    print(rule + "\n❯ \n" + rule + "\n   ⏵⏵ bypass permissions on", flush=True)
print("stub agent started", flush=True)
paint()
for line in sys.stdin:
    with open(sys.argv[1], "a") as inbox:
        inbox.write(line)
    paint()
PY
  start() { # start <name> <role> <bead>: a live session with a record and no hook
    local name=$1 role=$2 bead=$3 tree="$work/$1"
    git -C "$root" worktree add -q -b "feat/$name" "$tree" develop
    git -C "$tree" push -q -u origin "feat/$name"
    python3 - "$sessions/$name.json" "$name" "$role" "$bead" "$root" "$tree" <<'PY'
import json, sys
path, name, role, bead, root, tree = sys.argv[1:7]
record = {"name": name, "role": role, "agent": "claude", "state": "running", "working_dir": root,
          "launch_prompt": "autonomous", "kickoff_sent_at": "2026-10-30T00:00:00+00:00",
          "started_at": "2026-10-30T00:00:00+00:00", "log_path": root + "/" + name + ".log"}
if bead:
    record["bead_id"] = bead
    json.dump({"bead_id": bead, "path": tree}, open(root + "/.nogging/state/worktrees/implementation--b1.json", "w"))
json.dump(record, open(path, "w"))
PY
    tmux -L "$sock" new-session -d -s "$name" -x 120 -y 40 "python3 $work/runtime.py $work/$name.inbox"
  }
  wakes() { [[ -f "$work/$orch.inbox" ]] && grep -c '^\[nogg wake ' "$work/$orch.inbox" || echo 0; }
  nudges() { [[ -f "$work/lead-1.inbox" ]] && grep -c 'Nogging dispatcher' "$work/lead-1.inbox" || echo 0; }
  until_prompt() { for _ in $(seq 1 50); do tmux -L "$sock" capture-pane -p -t "$1" | grep -q '❯' && return 0; sleep 0.1; done; return 1; }
  dispatch() { "$nogg" session dispatch "$@"; }
  age() { # age: move every remembered clock and queued item back past its window
    python3 - "$root/.nogging/state" <<'PY'
import json, pathlib, sys
from datetime import datetime, timedelta, timezone
root = pathlib.Path(sys.argv[1])
old = (datetime.now(timezone.utc) - timedelta(seconds=1000)).isoformat()
path = root / "dispatch/state.json"
state = json.loads(path.read_text())
for session in state["sessions"].values():
    session["since"] = old
path.write_text(json.dumps(state))
PY
  }
  items() { python3 -c "import json,sys; print(','.join(sorted(i['kind'] for i in json.load(open(sys.argv[1])).get('items') or [])))" "$queue_file"; }
  turn_end() { printf '{"event": "turn_end", "session": "%s", "timestamp": "%s"}\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" >>"$sessions/$1.events.jsonl"; }

  start lead-1 lead B1
  start "$orch" orchestrator ""
  until_prompt lead-1 || bad "fixture: the Lead never painted a prompt"
  until_prompt "$orch" || bad "fixture: the orchestrator never painted a prompt"
  turn_end lead-1; turn_end "$orch"
  # An idle Lead with uncommitted work: a nudge is due.
  echo wip >"$work/lead-1/wip.txt"

  # While paused: no nudge, and the settle clock still runs.
  "$nogg" pause --days 1 >/dev/null
  dispatch --once >/dev/null; age
  dispatch --once >/dev/null; age
  dispatch --once >/dev/null; sleep 0.3
  expect "paused: a running Lead gets no nudge" "0" "$(nudges)"
  tmux -L "$sock" has-session -t lead-1 2>/dev/null && ok "paused: the Lead keeps running" || bad "paused: the Lead was stopped"

  # An item appears: it is queued and audited, and nothing reaches the orchestrator.
  rm "$work/lead-1/wip.txt"
  python3 - "$sessions/lead-1.events.jsonl" <<'PY'
import json, sys
from datetime import datetime, timezone
stamp = datetime.now(timezone.utc).isoformat()
open(sys.argv[1], "a").write(json.dumps({"event": "blocked", "session": "lead-1", "timestamp": stamp, "excerpt": "needs a decision"}) + "\n"
                             + json.dumps({"event": "turn_end", "session": "lead-1", "timestamp": stamp}) + "\n")
PY
  dispatch --once >/dev/null; age; dispatch --once >/dev/null
  expect "paused: the item is queued" "blocked" "$(items)"
  python3 - "$queue_file" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
queue = json.load(open(sys.argv[1]))
for item in queue["items"]:
    item["created_at"] = (datetime.now(timezone.utc) - timedelta(seconds=1000)).isoformat()
json.dump(queue, open(sys.argv[1], "w"))
PY
  out=$(dispatch --once)
  has "paused: the pass says why it held" "held: paused until" "$out"
  sleep 0.3
  expect "paused: nothing reaches the orchestrator" "0" "$(wakes)"
  has "paused: the item is in the audit log" '"action": "item"' "$(cat "$dispatch_dir/dispatch.jsonl")"
  has "inbox: it counts the held item" "PAUSED until" "$("$nogg" session inbox)"
  has "inbox: one item is held" "1 item(s) held" "$("$nogg" session inbox)"

  # A dry run ends nothing and sends nothing.
  dispatch --dry-run --json >/dev/null
  [[ -e "$pause_file" ]] && ok "dry-run: the pause stays" || bad "dry-run: it ended the pause"

  # Resume queues the summary, and the next idle pass sends everything as one digest.
  "$nogg" resume >/dev/null
  [[ ! -e "$pause_file" ]] && ok "resume: the state is gone" || bad "resume: the state stayed"
  expect "resume: the summary joins the held item" "blocked,resumed" "$(items)"
  dispatch --once >/dev/null
  for _ in $(seq 1 50); do [[ "$(wakes)" == 1 ]] && break; sleep 0.1; done
  sleep 0.3
  expect "resume: one digest" "1" "$(wakes)"
  has "resume: the digest carries both" "items=2 urgent=1" "$(cat "$work/$orch.inbox")"
  has "resume: it says what happened" "item(s) seen" "$(cat "$work/$orch.inbox")"
  expect "resume: the queue is empty" "" "$(items)"
  dispatch --once >/dev/null; sleep 0.3
  expect "resume: a replayed pass wakes nobody" "1" "$(wakes)"

  # A pause ends at its time: a tick one minute later, two items held and one that cleared.
  python3 - "$queue_file" "$dispatch_dir/dispatch.jsonl" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
now = datetime.now(timezone.utc)
stamp = (now - timedelta(days=1)).isoformat()
queue = json.load(open(sys.argv[1]))
queue["deliveries"] = []
queue["items"] = [{"key": f"gone-{n}|error|m", "kind": "error", "session": f"gone-{n}", "sticky": True, "reason": f"held {n}",
                   "next": "bd show B1", "created_at": stamp} for n in (1, 2)]
json.dump(queue, open(sys.argv[1], "w"))
rows = [{"time": stamp, "session": f"gone-{n}", "action": "item", "kind": "error", "key": f"gone-{n}|error|m", "outcome": "queued"}
        for n in (1, 2)]
rows += [{"time": stamp, "session": "gone-3", "action": "item", "kind": "ready_for_review", "key": "c", "outcome": "queued"},
         {"time": stamp, "session": "gone-3", "action": "item", "kind": "ready_for_review", "key": "c", "outcome": "cleared"}]
open(sys.argv[2], "w").write("".join(json.dumps(row) + "\n" for row in rows))
PY
  write_pause 1 2
  "$nogg" loop tick
  [[ ! -e "$pause_file" ]] && ok "end: a tick removes the state" || bad "end: the tick left it"
  expect "end: the summary is queued" "error,error,resumed" "$(items)"
  dispatch --once >/dev/null
  for _ in $(seq 1 50); do [[ "$(wakes)" == 2 ]] && break; sleep 0.1; done
  sleep 0.3
  expect "end: one digest" "2" "$(wakes)"
  has "end: it holds the summary and the two items" "items=3" "$(tail -n 12 "$work/$orch.inbox")"
  has "end: the counts" "3 item(s) seen, 1 cleared on their own; finished: gone-3" "$(cat "$work/$orch.inbox")"

  # `session dispatch --once` ends a pause too, and delivers in the same pass.
  python3 - "$dispatch_dir/dispatch.jsonl" "$queue_file" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
stamp = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
open(sys.argv[1], "a").write(json.dumps({"time": stamp, "session": "gone-4", "action": "item", "kind": "blocked",
                                         "key": "d", "outcome": "cleared"}) + "\n")
queue = json.load(open(sys.argv[2]))
queue["deliveries"] = []
json.dump(queue, open(sys.argv[2], "w"))
PY
  write_pause 1 1
  dispatch --once >/dev/null
  [[ ! -e "$pause_file" ]] && ok "dispatch: a pass ends the pause" || bad "dispatch: the pass left it"
  for _ in $(seq 1 50); do [[ "$(wakes)" == 3 ]] && break; sleep 0.1; done
  expect "dispatch: the same pass delivers" "3" "$(wakes)"
fi

# --- shipped files ----------------------------------------------------------
for shipped in bin/lib/manifest.js package.json; do
  if [[ -f "$repo_root/$shipped" ]]; then
    grep -q "scripts/lib/session_pause.py" "$repo_root/$shipped" && ok "$shipped ships session_pause.py" || bad "$shipped misses session_pause.py"
  fi
done
if [[ -f "$repo_root/package.json" ]]; then
  grep -q "session_pause_test.py" "$repo_root/package.json" && bad "package.json ships the test" || ok "package.json ships no test"
fi

[[ $fail -eq 0 ]] || { echo "session-pause: checks failed" >&2; exit 1; }
echo "session-pause: ok"
