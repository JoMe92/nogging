#!/usr/bin/env bash
# TASK-SWK-010 (openspec/changes/session-wake): quiet hours, the keep-warm and the one
# compaction. The table of design Decision 15 is pure cases in session_warm_test.py with an
# injected clock; this file covers the sends with a clock passed in, the size the `Stop`
# hook records, one real pass to a stub orchestrator on a private socket that is idle,
# working or holding input, and the refusal of a malformed window. Offline: stub agents,
# stub gh, stub bd.
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
if [[ -f "$here/lib/session_warm_test.py" ]]; then
  python3 "$here/lib/session_warm_test.py" >"$work/unit.out" 2>&1 && ok "session_warm_test.py" \
    || { bad "session_warm_test.py"; cat "$work/unit.out"; }
else
  ok "session_warm_test.py skipped (installed consumer copy)"
fi

# --- the sends with an injected clock: the target and the send are stubbed --------
python3 - "$nogg" "$work/sends" <<'PY' && ok "sends: every gate, a refused and an unverified send" || bad "sends: see above"
import json, os, pathlib, signal, stat, sys
from datetime import datetime, timedelta, timezone
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
m = SourceFileLoader("sf_swk010", sys.argv[1]).load_module()
warm, wake = m.warm_module(), m.wake_module()
state = pathlib.Path(sys.argv[2]); state.mkdir()
t0 = datetime(2026, 10, 30, 12, 0, tzinfo=timezone.utc)
record = {"name": "orch", "agent": "claude", "requested_model": "opus"}
events = state / "orch.events.jsonl"
pause_file = state / "pause.json"
live = [{"session": "lead", "state": "idle"}]
over = {"windows": [{"bucket": "short", "status": "known", "used_percent": 90}]}

def turn(minutes, tokens=180000):
    stamp = (t0 - timedelta(minutes=minutes)).isoformat()
    events.write_text(json.dumps({"event": "turn_end", "timestamp": stamp, "context_tokens": tokens}) + "\n")

def step(facts=live, target=(record, "idle"), usage=None, send=None, pause=None, pulls=False, moment=t0, dry_run=False,
         config=None):
    sent = []
    targets = target if isinstance(target, list) else None
    with patch.object(m, "dispatch_dir", return_value=state), \
         patch.object(m, "session_events_path", return_value=events), \
         patch.object(m, "pause_path", return_value=pause_file), \
         patch.object(m, "orchestrator_target", side_effect=(lambda: targets.pop(0)) if targets else (lambda: target)), \
         patch.object(m, "orchestrator_send", side_effect=send or (lambda _r, text: sent.append(text))), \
         patch.object(m, "_orchestrator_usage", return_value=usage), \
         patch.object(m, "_open_pull_request", return_value=pulls), \
         patch.dict(m.CFG, {"session_dispatch": config or {}}):
        return m._warm_step(facts, moment, dry_run, pause), sent

def reset():
    (state / "warm.json").unlink(missing_ok=True)
    (state / "dispatch.jsonl").unlink(missing_ok=True)

KEEP = '[nogg keepwarm] No action. Answer "ok" in one short line and use no tools.'

# The fixed line, once per interval, and not to a turn that has not been idle long enough.
turn(50)
result, sent = step()
assert result == {"action": "keep-warm", "outcome": "sent"} and sent == [KEEP], (result, sent)
assert step() == (None, [])
turn(18)
assert step() == (None, [])
turn(50)
reset()

# A keep-warm is no wake: a digest due at the same moment still goes out.
step()
queue = {"items": [{"key": "s1|ready_for_review|m", "kind": "ready_for_review", "session": "s1", "bead": "B1",
                    "reason": "r", "next": "n", "created_at": (t0 - timedelta(hours=1)).isoformat()}]}
assert "deliveries" not in queue
plan = wake.plan(queue, wake.policy_from(None), t0)
assert plan["hold"] is None and plan["items"], plan
reset()

# It waits under the usage hold, which it writes down once, and sends when that lifts.
for _ in range(3):
    result, sent = step(usage=over)
    assert result == {"action": "keep-warm", "outcome": "held: usage short 90%"} and sent == [], (result, sent)
assert len((state / "dispatch.jsonl").read_text().splitlines()) == 1
assert step()[1] == [KEEP]
reset()

# The state is the last thing read: a turn that starts meanwhile holds it.
result, sent = step(target=[(record, "idle"), (record, "working")])
assert result["outcome"] == "held: orchestrator working" and sent == [], (result, sent)
reset()

# Only idle: not a session that is working, waiting or holding the prompt for a person.
for held in ("working", "waiting_background", "needs_input", "limit"):
    assert step(target=(record, held)) == (None, []), held
assert step(target=(None, "target-not-running")) == (None, [])
assert step(target=({**record, "agent": "codex"}, "idle")) == (None, [])
assert step(target=({**record, "agent": "pi"}, "idle"), facts=[]) == (None, [])

# A turn that did not end, or a missing file, is no interval.
events.write_text(json.dumps({"event": "turn_start", "timestamp": t0.isoformat()}) + "\n")
assert step() == (None, [])
events.unlink()
assert step() == (None, [])
turn(50)

# keep_warm false sends none and leaves the compaction rule alone.
off = {"wake": {"keep_warm": False}}
assert step(config=off) == (None, [])
assert step(facts=[], config=off)[0] == {"action": "compact", "outcome": "sent"}
reset()

# A refusal typed nothing, so a later pass tries again, and the audit says it once.
def refused(_record, _text):
    raise RuntimeError("orch: composer is other; nothing was typed or submitted")
for _ in range(3):
    result, sent = step(send=refused)
    assert result["outcome"].startswith("failed: orch: composer is other") and sent == [], (result, sent)
assert "warmed_at" not in json.loads((state / "warm.json").read_text()) or \
    json.loads((state / "warm.json").read_text())["warmed_at"] is None
assert len((state / "dispatch.jsonl").read_text().splitlines()) == 1
assert step()[1] == [KEEP]
assert step() == (None, [])
reset()

# A send that may have landed is spent: at most one per interval.
def unverified(_record, _text):
    raise RuntimeError("orch: message still unverified owner@example.com")
result, _ = step(send=unverified)
assert result["outcome"].startswith("failed: orch: message still unverified"), result
assert "owner@example.com" not in (state / "dispatch.jsonl").read_text()
assert step() == (None, [])
reset()

# The record comes before the send: with no way to keep it, nothing is sent.
sent_any = []
with patch.object(m, "atomic_json_state", side_effect=OSError("read-only file system")):
    try:
        step(send=lambda _r, text: sent_any.append(text))
    except OSError:
        pass
    else:
        raise AssertionError("the write failure must stop the send")
assert sent_any == []

# The guarded step costs no pass.
with patch.object(m, "_warm_step", side_effect=RuntimeError("tmux is gone")):
    assert m._warm_guarded([], t0, False, None) is None

# A dry run shows the plan and sends nothing, writes nothing.
reset()
assert step(dry_run=True) == ({"action": "keep-warm", "outcome": "dry-run"}, [])
assert not (state / "warm.json").exists()

# Activity: a planner counts, gone sessions do not, unreadable ones are unknown.
assert step(facts=[{"session": "p", "state": "working"}], dry_run=True)[0]["action"] == "keep-warm"
assert step(facts=[{"session": "l", "state": "gone"}], dry_run=True)[0]["action"] == "compact"
assert step(facts=[{"session": "l", "state": "unknown"}], dry_run=True) == (None, [])
assert step(facts=[{"session": "l", "state": "unknown"}, {"session": "k", "state": "idle"}],
            dry_run=True)[0]["action"] == "keep-warm"
assert step(facts=[], pulls=True, dry_run=True)[0]["action"] == "keep-warm"
assert step(facts=[], pulls=None, dry_run=True) == (None, [])

# Nothing active: one compaction, then the cache lapses.
result, sent = step(facts=[])
assert result == {"action": "compact", "outcome": "sent"} and len(sent) == 1, (result, sent)
assert sent[0].startswith("/compact ") and "\n" not in sent[0], sent
assert step(facts=[]) == (None, [])
reset()

# The usage hold is the keep-warm's: the spec holds no compaction under it.
assert step(facts=[], usage=over)[0]["outcome"] == "sent"
reset()

# A size that could not be read, or a small context, is no compaction.
turn(50, None); assert step(facts=[]) == (None, [])
turn(50, 90000); assert step(facts=[]) == (None, [])
turn(70); assert step(facts=[]) == (None, [])
turn(50)

# A pause forces the compaction branch, reads no pull request and records it in pause.json.
pause = {"schema": 1, "started_at": (t0 - timedelta(hours=1)).isoformat(), "until": (t0 + timedelta(days=1)).isoformat(),
         "keep_loops": [], "set_by": "operator", "compacted_at": None}
with patch.object(m, "_work_is_active", side_effect=AssertionError("read the activity")):
    result, sent = step(pause=pause)
assert result == {"action": "compact", "outcome": "sent"} and sent[0].startswith("/compact "), (result, sent)
written = json.loads(pause_file.read_text())
assert written["compacted_at"] == json.loads((state / "warm.json").read_text())["compacted_at"], written
assert step(pause=pause) == (None, [])

# The pause's own record holds even without warm.json, because a replaced pause keeps it.
reset()
assert step(pause=written) == (None, [])
pause_file.unlink()

# Quiet hours hold the digest with their reason, a pause and a failed end first.
local = t0.astimezone()
window = f"{local:%H}:00-{(local + timedelta(hours=1)):%H}:00"
with patch.dict(m.CFG, {"session_dispatch": {"wake": {"quiet_hours": [window]}}}):
    assert m.dispatch_wake_hold(moment=t0) == f"quiet hours {window}"
    assert m.dispatch_wake_hold(moment=t0 + timedelta(hours=2)) is None
    assert m.dispatch_wake_hold(pause, moment=t0).startswith("paused until ")
    assert m.dispatch_wake_hold(None, True, t0) == "the pause could not be ended"
    assert m.dispatch_policy()["hold_sends"] is False, "quiet hours stop no nudge"
    reset(); turn(50)
    assert m.warm_policy()["quiet_hours"] == [window]
    with patch.object(m, "_work_is_active", side_effect=AssertionError("read the activity")):
        result, sent = step(moment=t0, config={"wake": {"quiet_hours": [window]}})
    assert result == {"action": "compact", "outcome": "sent"} and sent[0].startswith("/compact "), (result, sent)

# The cached pull request answer, and a failed read is never the older copy.
reset()
class Done:
    def __init__(self, code, out): self.returncode, self.stdout = code, out
with patch.object(m, "dispatch_dir", return_value=state):
    with patch.object(m, "run", return_value=Done(0, '[{"number": 1}]')) as gh:
        assert m._open_pull_request(False) is True and m._open_pull_request(False) is True
        assert gh.call_count == 1, gh.call_count
        assert "open" in gh.call_args[0] and "--limit" in gh.call_args[0] and gh.call_args[1]["timeout"] > 0
    (state / "pulls.json").unlink()
    with patch.object(m, "run", return_value=Done(1, "")):
        assert m._open_pull_request(False) is None and not (state / "pulls.json").exists()
    with patch.object(m, "run", return_value=Done(0, "{not json")):
        assert m._open_pull_request(False) is None
    with patch.object(m, "run", return_value=Done(0, '{"a": 1}')):
        assert m._open_pull_request(False) is None
    with patch.object(m, "run", side_effect=FileNotFoundError("gh")):
        assert m._open_pull_request(False) is None
    with patch.object(m, "run", return_value=Done(0, "[]")):
        assert m._open_pull_request(True) is False and not (state / "pulls.json").exists()

# The transcript: bounded, regular files only, a number or None, never a failed hook.
tail = state / "tail.jsonl"
usage = {"input_tokens": 1, "cache_read_input_tokens": 179999, "output_tokens": 9}
tail.write_text(json.dumps({"type": "assistant", "message": {"usage": usage}}) + "\n")
assert m._hook_context_tokens({"transcript_path": str(tail)}) == 180000
big = state / "big.jsonl"
big.write_text(json.dumps({"type": "assistant", "message": {"usage": usage}}) + "\n" + "x" * (warm.TRANSCRIPT_TAIL_BYTES + 1))
assert m._hook_context_tokens({"transcript_path": str(big)}) is None
link = state / "link.jsonl"; link.symlink_to(tail)
fifo = state / "fifo.jsonl"; os.mkfifo(fifo)
for value in ({}, {"transcript_path": None}, {"transcript_path": 7}, {"transcript_path": str(state / "none")},
              {"transcript_path": "a\0b"}, {"transcript_path": str(link)}, {"transcript_path": str(fifo)},
              {"transcript_path": str(state)}):
    assert m._hook_context_tokens(value) is None, value
with patch.object(m, "warm_module", side_effect=ImportError("a partial upgrade")):
    assert m._hook_context_tokens({"transcript_path": str(tail)}) is None

# A planted FIFO or link cannot hold a `Stop` open or redirect the append.
signal.alarm(20)
for planted, make in (("fifo", os.mkfifo), ("link", lambda path: os.symlink(tail, path))):
    path = state / f"{planted}.events.jsonl"
    make(path)
    before = tail.read_text()
    with patch.object(m, "session_events_path", return_value=path):
        m._append_session_event("orch", {"event": "turn_end"})
    assert stat.S_ISREG(os.lstat(path).st_mode) and json.loads(path.read_text())["event"] == "turn_end", planted
    assert tail.read_text() == before and list(state.glob(f"{planted}.events.jsonl.corrupt.*")), planted
signal.alarm(0)

# A line nested past the parser's depth is skipped: every pass reads this file.
deep = state / "deep.events.jsonl"
deep.write_text("[" * 200000 + "\n" + json.dumps({"event": "turn_end"}) + "\n")
assert m.signals_module().read_events(deep) == [{"event": "turn_end"}]

# The doctor adds no line for a missing orchestrator, which has its own, or with dispatch off.
with patch.object(m, "orchestrator_target", return_value=(None, "target-not-running")):
    with patch.dict(m.CFG, {"session_dispatch": {"enabled": True}}):
        assert m.warm_diagnostics() == []
with patch.dict(m.CFG, {"session_dispatch": {"enabled": False}}):
    assert m.warm_diagnostics() == []
PY

# --- the `Stop` hook records the size for the orchestrator alone ------------------
mkdir -p "$work/hook/.nogging/state/sessions"
copy_host_config "$repo_root/.nogging/config.json" "$work/hook/.nogging/config.json"
git -C "$work/hook" init -q -b develop
printf '{"type":"assistant","message":{"usage":{"input_tokens":180000}}}\n' >"$work/hook/transcript.jsonl"
hook() { # hook <name> <role> <agent>
  printf '{"name": "%s", "role": "%s", "agent": "%s", "state": "running", "working_dir": "%s"}' "$1" "$2" "$3" "$work/hook" \
    >"$work/hook/.nogging/state/sessions/$1.json"
  printf '{"transcript_path": "%s"}' "$work/hook/transcript.jsonl" |
    NOGGING_ROOT="$work/hook" NOGG_SESSION_NAME="$1" NOGG_SESSION_ROLE="$2" NOGG_SESSION_AGENT="$3" "$nogg" session emit turn_end
  python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1]).get("context_tokens"))' \
    "$work/hook/.nogging/state/sessions/$1.events.jsonl"
}
expect "stop hook: the orchestrator's size is recorded" "180000" "$(hook orch orchestrator claude)"
expect "stop hook: a Lead reads no transcript" "None" "$(hook lead lead claude)"
lacks "stop hook: the path stays out of the event" "transcript" "$(cat "$work/hook/.nogging/state/sessions/orch.events.jsonl")"

# --- one real pass: a stub orchestrator on a private socket ---------------------
if ! command -v tmux >/dev/null; then
  ok "integration skipped (tmux unavailable)"
else
  export HOME="$work/home"; mkdir -p "$HOME"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  # A socket path must stay under 108 bytes, whatever TMPDIR is.
  export TMUX_TMPDIR; TMUX_TMPDIR=$(mktemp -d /tmp/nogg-warm.XXXXXX)
  export NOGG_TEST_ARGS_DIR="$work/args"; mkdir -p "$NOGG_TEST_ARGS_DIR"
  sock="nogg-swk010-$$"
  trap 'tmux -L "$sock" kill-server 2>/dev/null || true; rm -rf "$work" "$TMUX_TMPDIR"' EXIT
  root="$work/root"
  sessions="$root/.nogging/state/sessions"
  dispatch_dir="$root/.nogging/state/dispatch"
  queue_file="$dispatch_dir/queue.json"
  orch="nogg-orchestrator-root"
  config="$root/.nogging/config.json"
  mkdir -p "$sessions" "$root/.nogging/state/worktrees" "$root/scripts" "$work/bin"
  copy_host_config "$repo_root/.nogging/config.json" "$config"
  export NOGGING_ROOT="$root"
  set_windows() { # set_windows <json list>: the quiet hours of the next pass
    python3 - "$config" "$sock" "$1" <<'PY'
import json, sys
path, sock, windows = sys.argv[1:4]
config = json.load(open(path))
config.update(session_tmux_socket=sock, session_backend="tmux",
              session_dispatch={"enabled": True, "wake": {"quiet_hours": json.loads(windows)}})
config["usage_gate"] = {"enabled": False}
json.dump(config, open(path, "w"), indent=2)
PY
  }
  around_now() { python3 -c '
from datetime import datetime, timedelta
now = datetime.now()
print(f"\"{now - timedelta(hours=1):%H:%M}-{now + timedelta(hours=1):%H:%M}\"")'; }
  away_from_now() { python3 -c '
from datetime import datetime, timedelta
now = datetime.now()
print(f"\"{now + timedelta(hours=2):%H:%M}-{now + timedelta(hours=3):%H:%M}\"")'; }
  set_windows "[$(around_now)]"
  git init -q --bare -b develop "$work/upstream.git"
  git -C "$root" init -q -b develop
  printf '.nogging/\nscripts/\n' >"$root/.gitignore"
  git -C "$root" add .gitignore; git -C "$root" commit -qm init
  git -C "$root" remote add origin "$work/upstream.git"; git -C "$root" push -q -u origin develop

  printf '#!/bin/sh\ncat "%s/gh.json"\n' "$work" >"$work/bin/gh"
  printf '#!/bin/sh\ncat "%s/bd.json"\n' "$work" >"$work/bin/bd"
  chmod +x "$work/bin/gh" "$work/bin/bd"; export PATH="$work/bin:$PATH"
  echo '[]' >"$work/gh.json"
  printf '[{"id":"B1","status":"in_progress"},{"id":"B2","status":"in_progress"}]\n' >"$work/bd.json"
  cat >"$work/runtime.py" <<'PY'
import sys
rule = "─" * 80
def paint(typed=""):
    print(rule + "\n❯ " + typed + "\n" + rule + "\n   ⏵⏵ bypass permissions on", flush=True)
print("stub agent started", flush=True)
paint()
for line in sys.stdin:
    if line.strip() in ("::hold", "::free"):
        paint("typed by the owner" if line.strip() == "::hold" else "")
        continue
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
    json.dump({"bead_id": bead, "path": tree},
              open(root + "/.nogging/state/worktrees/implementation--" + bead.lower() + ".json", "w"))
json.dump(record, open(path, "w"))
PY
    tmux -L "$sock" new-session -d -s "$name" -x 120 -y 40 "python3 $work/runtime.py $work/$name.inbox"
  }
  lines() { [[ -f "$work/$1.inbox" ]] && { grep -c "^$2" "$work/$1.inbox" || true; } || echo 0; }
  until_prompt() { for _ in $(seq 1 50); do tmux -L "$sock" capture-pane -p -t "$1" | grep -q '❯' && return 0; sleep 0.1; done; return 1; }
  until_lines() { for _ in $(seq 1 50); do [[ "$(lines "$1" "$2")" == "$3" ]] && return 0; sleep 0.1; done; return 0; }
  dispatch() { "$nogg" session dispatch --once; }
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
path = root / "dispatch/queue.json"
queue = json.loads(path.read_text())
for item in queue.get("items") or []:
    item["created_at"] = old
queue.pop("failed_at", None); queue.pop("failures", None)
path.write_text(json.dumps(queue))
PY
  }
  items() { python3 -c "import json,sys; print(','.join(i['kind'] for i in json.load(open(sys.argv[1])).get('items') or []))" "$queue_file"; }
  turn_ended() { # turn_ended <minutes ago> [size]: the orchestrator's last hook line
    python3 - "$sessions/$orch.events.jsonl" "$1" "${2:-180000}" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
path, minutes, size = sys.argv[1:4]
stamp = (datetime.now(timezone.utc) - timedelta(minutes=int(minutes))).isoformat()
open(path, "w").write(json.dumps({"event": "turn_end", "timestamp": stamp, "context_tokens": int(size)}) + "\n")
PY
  }
  no_deliveries() { python3 - "$queue_file" <<'PY'
import json, sys
queue = json.load(open(sys.argv[1]))
queue["deliveries"] = []
json.dump(queue, open(sys.argv[1], "w"))
PY
  }

  start lead-1 lead B1
  start lead-2 lead B2
  start "$orch" orchestrator ""
  for name in lead-1 lead-2 "$orch"; do until_prompt "$name" || bad "fixture: $name never painted a prompt"; done
  git -C "$work/lead-1" commit -q --allow-empty -m "wip"; git -C "$work/lead-1" push -q
  turn_ended 5
  python3 - "$sessions" <<'PY'
import json, pathlib, sys
from datetime import datetime, timezone
stamp = datetime.now(timezone.utc).isoformat()
end = json.dumps({"event": "turn_end", "session": "lead-1", "timestamp": stamp})
(pathlib.Path(sys.argv[1]) / "lead-1.events.jsonl").write_text(json.dumps(
    {"event": "blocked", "session": "lead-1", "timestamp": stamp, "excerpt": "needs a decision"}) + "\n" + end + "\n")
(pathlib.Path(sys.argv[1]) / "lead-2.events.jsonl").write_text(end.replace("lead-1", "lead-2") + "\n")
PY
  touch "$work/lead-2/uncommitted"

  # Inside a window: an urgent item is held, with its reason, and a Lead is still nudged.
  dispatch >/dev/null; age; dispatch >/dev/null; age
  out=$(dispatch)
  has "window: the pass says why" "held: quiet hours" "$out"
  expect "window: the urgent item waits" "0" "$(lines "$orch" '\[nogg wake ')"
  expect "window: it stays queued" "blocked" "$(items)"
  has "window: the inbox shows the hold" "delivery held: quiet hours" "$("$nogg" session inbox)"
  until_lines lead-2 'Nogging dispatcher:' 1
  expect "window: a Lead is still nudged" "1" "$(lines lead-2 'Nogging dispatcher:')"
  rm -f "$work/lead-2/uncommitted"
  age
  dispatch >/dev/null
  expect "window: the replay still sends nothing" "0" "$(lines "$orch" '\[nogg wake ')"

  # The first pass after it delivers what still holds, as one digest.
  set_windows "[$(away_from_now)]"
  age
  out=$(dispatch)
  until_lines "$orch" '\[nogg wake ' 1
  expect "after: one digest" "1" "$(lines "$orch" '\[nogg wake ')"
  expect "after: the queue is empty" "" "$(items)"
  lacks "after: no keep-warm beside a wake" "warm keep-warm" "$out"

  # Active: one keep-warm after the interval, and none on the next pass.
  no_deliveries
  turn_ended 50
  out=$(dispatch)
  has "keep-warm: the pass reports it" "warm keep-warm: sent" "$out"
  until_lines "$orch" '\[nogg keepwarm\] ' 1
  expect "keep-warm: the fixed line" '[nogg keepwarm] No action. Answer "ok" in one short line and use no tools.' \
    "$(grep -F '[nogg keepwarm]' "$work/$orch.inbox" | tr -d '\r')"
  dispatch >/dev/null; sleep 0.3
  expect "keep-warm: once per interval" "1" "$(lines "$orch" '\[nogg keepwarm\] ')"
  has "keep-warm: audited" '"kind": "keep-warm"' "$(cat "$dispatch_dir/dispatch.jsonl")"
  expect "keep-warm: it is no wake" "0" \
    "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("deliveries") or []))' "$queue_file")"

  # A real turn after it starts a new interval, and the next one is due 50 minutes on.
  turn_ended 18
  dispatch >/dev/null; sleep 0.3
  expect "reset: nothing inside the interval" "1" "$(lines "$orch" '\[nogg keepwarm\] ')"
  # A fixture turn dated back cannot end after a send of a moment ago, so the send goes too.
  rm -f "$dispatch_dir/warm.json"
  turn_ended 50
  dispatch >/dev/null
  until_lines "$orch" '\[nogg keepwarm\] ' 2
  expect "reset: a new interval has its own" "2" "$(lines "$orch" '\[nogg keepwarm\] ')"

  # A lapsed cache is left to lapse.
  turn_ended 70
  dispatch >/dev/null; sleep 0.3
  expect "lapsed: nothing is sent" "2" "$(lines "$orch" '\[nogg keepwarm\] ')"

  # Holding input: the composer refusal touches nothing, and the next pass may try.
  rm -f "$dispatch_dir/warm.json"
  turn_ended 51
  tmux -L "$sock" send-keys -t "$orch" "::hold" Enter; sleep 0.2
  out=$(env -u NOGG_TEST_ARGS_DIR "$nogg" session dispatch --once 2>&1) || bad "input: the pass failed: $out"
  has "input: the refusal is reported" "composer is" "$out"
  expect "input: nothing reaches the orchestrator" "2" "$(lines "$orch" '\[nogg keepwarm\] ')"
  tmux -L "$sock" send-keys -t "$orch" "::free" Enter; sleep 0.2

  # Working: not touched.
  python3 - "$sessions/$orch.events.jsonl" <<'PY'
import json, sys
from datetime import datetime, timezone
open(sys.argv[1], "a").write(json.dumps({"event": "turn_start", "timestamp": datetime.now(timezone.utc).isoformat()}) + "\n")
PY
  dispatch >/dev/null; sleep 0.3
  expect "working: nothing is sent" "2" "$(lines "$orch" '\[nogg keepwarm\] ')"
  rm -f "$dispatch_dir/warm.json"

  # Paused: no keep-warm with a live Lead, one compaction, kept in pause.json.
  "$nogg" pause --days 1 >/dev/null
  turn_ended 50
  dispatch >/dev/null
  until_lines "$orch" '/compact ' 1
  expect "pause: one compaction" "1" "$(lines "$orch" '/compact ')"
  expect "pause: no keep-warm" "2" "$(lines "$orch" '\[nogg keepwarm\] ')"
  has "pause: recorded in its file" "compacted_at" "$(python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print("compacted_at" if s["compacted_at"] else "none")' "$root/.nogging/state/pause.json")"
  dispatch >/dev/null; sleep 0.3
  expect "pause: once per idle period" "1" "$(lines "$orch" '/compact ')"
  "$nogg" resume >/dev/null

  # The doctor's line, with the settings and the next compaction.
  turn_ended 10
  rm -f "$dispatch_dir/warm.json"
  set_windows '["01:00-02:00"]'
  note=$("$nogg" doctor 2>&1 || true)
  has "doctor: keep-warm" "session warm: keep-warm after 50m" "$note"
  has "doctor: quiet hours" "quiet hours 01:00-02:00" "$note"
  has "doctor: the next compaction" "next compaction" "$note"

  # A malformed window fails validate, doctor and the pass, naming it.
  set_windows '["25:00-07:00"]'
  note=$("$nogg" validate 2>&1 || true)
  has "malformed: validate names it" "'25:00-07:00'" "$note"
  has "malformed: doctor fails naming it" "FAIL  session dispatch config: session_dispatch.wake.quiet_hours" "$("$nogg" doctor 2>&1 || true)"
  if out=$(dispatch 2>&1); then bad "malformed: the pass ran"; else has "malformed: the pass is refused" "'25:00-07:00'" "$out"; fi
fi

# --- the orchestrator's rules ---------------------------------------------------
for guide in "$repo_root/.nogging/launch-prompts/orchestrator.md" "$repo_root/.claude/commands/orchestrate.md"; do
  name=${guide##*/}
  [[ -f "$guide" ]] || { ok "$name skipped (installed consumer copy)"; continue; }
  for phrase in '`[nogg keepwarm' 'one short line' 'no tool' 'nogg pause --days 3' 'nogg pause --status' \
                'stops automation'; do
    grep -qF -- "$phrase" "$guide" && ok "$name: $phrase" || bad "$name misses: $phrase"
  done
done

# --- shipped files ----------------------------------------------------------
for shipped in bin/lib/manifest.js package.json; do
  if [[ -f "$repo_root/$shipped" ]]; then
    grep -q "scripts/lib/session_warm.py" "$repo_root/$shipped" && ok "$shipped ships session_warm.py" || bad "$shipped misses session_warm.py"
  fi
done
if [[ -f "$repo_root/package.json" ]]; then
  grep -q "session_warm_test.py" "$repo_root/package.json" && bad "package.json ships the test" || ok "package.json ships no test"
fi

[[ $fail -eq 0 ]] || { echo "session-warm: checks failed" >&2; exit 1; }
echo "session-warm: ok"
