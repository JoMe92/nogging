#!/usr/bin/env bash
# TASK-SWK-004 (openspec/changes/session-wake): the dispatcher. The Decision 7 table
# is pure decide() cases in session_dispatch_test.py; this file covers the config
# refusal and one real pass. Offline: stub agents on a private socket, stub gh, stub bd.
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

# --- the pure decision (source-only; an installed consumer skips) ---------------
if [[ -f "$here/lib/session_dispatch_test.py" ]]; then
  python3 "$here/lib/session_dispatch_test.py" >"$work/unit.out" 2>&1 && ok "session_dispatch_test.py" \
    || { bad "session_dispatch_test.py"; cat "$work/unit.out"; }
else
  ok "session_dispatch_test.py skipped (installed consumer copy)"
fi

# --- config refusal through doctor ----------------------------------------------
diagnose() { # diagnose <json>: the config diagnostics for that config
  python3 - "$nogg" "$1" <<'PY'
import json, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_swk004", sys.argv[1]).load_module()
m.CFG = dict(m.CFG, **json.loads(sys.argv[2]))
print("; ".join(line for line, _ in m.session_dispatch_diagnostics()))
PY
}
expect "config: a default install has no diagnostics" "" "$(diagnose '{}')"
expect "config: a typo is refused, naming the key" \
  "session dispatch config: session_dispatch: unknown key 'max_nudge'" "$(diagnose '{"session_dispatch": {"max_nudge": 2}}')"
expect "config: orchestrator_context refuses an unknown key too" \
  "session dispatch config: orchestrator_context: unknown key 'window'" "$(diagnose '{"orchestrator_context": {"window": 1}}')"
python3 - "$repo_root" "$here/lib" <<'PY' && ok "config: the template block is valid, disabled and retires nothing" || bad "config: template block"
import json, os, sys
sys.path.insert(0, sys.argv[2])
sys.dont_write_bytecode = True
import session_dispatch as d
path = os.path.join(sys.argv[1], "templates/nogging-config.json")
if os.path.exists(path):
    template = json.load(open(path))
    assert d.config_errors(template) == [], d.config_errors(template)
    assert template["session_dispatch"]["enabled"] is False
    assert template["session_dispatch"]["retire_merged"] is False
PY

# --- the action paths, with the session verbs stubbed ----------------------------
python3 - "$nogg" "$work/actions" <<'PY' && ok "actions: the send gate, resume, retirement and a failed step" || bad "actions: see above"
import json, pathlib, sys
from datetime import datetime, timezone
from importlib.machinery import SourceFileLoader
from unittest.mock import patch
m = SourceFileLoader("sf_swk004a", sys.argv[1]).load_module()
state = pathlib.Path(sys.argv[2]); state.mkdir()
now = datetime(2026, 10, 30, 12, tzinfo=timezone.utc)
def memory(): return {"sessions": {"s1": {}}}
fact = {"session": "s1", "bead": "B1"}
nudge = {"type": "nudge", "session": "s1", "key": "s1|gaps|h|1", "budget": "budget", "reason": "gaps", "text": "go"}
with patch.object(m, "dispatch_dir", return_value=state), patch.object(m, "load_session", return_value=(None, {"name": "s1"})):
    # A session that went busy after the gather keeps its budget and gets nothing.
    with patch.object(m, "classify_session", return_value=("working", "")), patch.object(m, "session_send") as send:
        mem = memory()
        assert m._dispatch_apply(nudge, fact, mem, {}, now) == "held"
        assert not send.called and "done" not in mem["sessions"]["s1"], mem
        once = dict(nudge, key="s1|stall|t", once=True, budget=None, reason="stall")
        assert m._dispatch_apply(once, fact, mem, {}, now) == "held"
        assert not send.called and mem["sessions"]["s1"]["done"] == ["s1|stall|t"], mem
    # An idle session is sent the fixed text through the verified path.
    with patch.object(m, "classify_session", return_value=("idle", "")), patch.object(m, "session_send") as send:
        mem = memory()
        assert m._dispatch_apply(nudge, fact, mem, {}, now) == "done"
        send.assert_called_once_with("s1", "go", verify=True)
        assert mem["sessions"]["s1"]["budget"]["nudges"] == 1, mem
    # An unverified send may have landed, so it is spent and never repeats unbounded.
    with patch.object(m, "classify_session", return_value=("idle", "")), \
         patch.object(m, "session_send", side_effect=RuntimeError("composer holds text for owner@example.com")):
        mem = memory()
        outcome = m._dispatch_apply(nudge, fact, mem, {}, now)
        assert outcome.startswith("failed:") and "owner@example.com" not in outcome, outcome
        assert mem["sessions"]["s1"]["budget"]["nudges"] == 1, mem
    # Retirement stops, then cleans up, and is told without an item.
    order, queue = [], {}
    retire = {"type": "retire", "session": "s1", "key": "s1|retire|h", "reason": "merged"}
    with patch.object(m, "session_stop", side_effect=lambda n, r: order.append(("stop", n, r))), \
         patch.object(m, "session_cleanup", side_effect=lambda n: order.append(("cleanup", n))):
        assert m._dispatch_apply(retire, fact, memory(), queue, now) == "done"
    assert order == [("stop", "s1", "retire-merged"), ("cleanup", "s1")], order
    assert "items" not in queue and queue["retired"][0]["session"] == "s1", queue
    # A failed resume goes up as `error` and is not retried.
    queue, mem = {}, memory()
    resume = {"type": "resume", "session": "s1", "key": "s1|resume|t", "reason": "limit-over"}
    with patch.object(m, "resume_step", side_effect=RuntimeError("no composer")):
        assert m._dispatch_apply(resume, fact, mem, queue, now).startswith("failed:")
    assert [i["kind"] for i in queue["items"]] == ["error"] and "s1|resume|t" in mem["sessions"]["s1"]["done"], queue
    # The audit log is redacted, line-oriented and rotates to three generations.
    rows = [json.loads(line) for line in (state / "dispatch.jsonl").read_text().splitlines()]
    assert all(set(r) >= {"time", "session", "action", "key", "reason", "outcome"} for r in rows), rows
    assert "owner@example.com" not in (state / "dispatch.jsonl").read_text()
    with patch.object(m, "DISPATCH_AUDIT_BYTES", 10):
        for n in range(6):
            m._append_dispatch_audit({"n": n})
    assert sorted(p.name for p in state.glob("dispatch.jsonl*")) == \
        ["dispatch.jsonl", "dispatch.jsonl.1", "dispatch.jsonl.2", "dispatch.jsonl.3"]
PY

# --- one real pass: stub agents on a private socket, stub gh, stub bd ------------
if ! command -v tmux >/dev/null; then
  ok "integration skipped (tmux unavailable)"
else
  export HOME="$work/home"; mkdir -p "$HOME"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  export TMUX_TMPDIR="$work/tmux"; mkdir -p "$TMUX_TMPDIR"
  # A legacy stub: it paints a prompt but does not redraw one as a real CLI would.
  export NOGG_TEST_ARGS_DIR="$work/args"; mkdir -p "$NOGG_TEST_ARGS_DIR"
  sock="nogg-swk004-$$"
  trap 'tmux -L "$sock" kill-server 2>/dev/null || true; rm -rf "$work"' EXIT
  root="$work/root"
  sessions="$root/.nogging/state/sessions"
  mkdir -p "$sessions" "$root/.nogging/state/worktrees" "$root/scripts" "$work/bin"
  copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
  export NOGGING_ROOT="$root"
  configure() { # configure <json merged into the fixture config>
    python3 - "$root/.nogging/config.json" "$sock" "$1" <<'PY'
import json, sys
path, sock, extra = sys.argv[1:4]
config = json.load(open(path))
config.pop("session_dispatch", None)
config.update(json.loads(extra), session_tmux_socket=sock, session_backend="tmux")
json.dump(config, open(path, "w"), indent=2)
PY
  }
  configure '{}'
  git init -q --bare -b develop "$work/upstream.git"
  git -C "$root" init -q -b develop
  printf '.nogging/\nscripts/\n' >"$root/.gitignore"
  git -C "$root" add .gitignore; git -C "$root" commit -qm init
  git -C "$root" remote add origin "$work/upstream.git"; git -C "$root" push -q -u origin develop

  cat >"$work/bin/gh" <<EOF
#!/bin/sh
echo call >>"$work/gh.calls"
[ -e "$work/gh.fail" ] && exit 1
cat "$work/gh.json"
EOF
  cat >"$work/bin/bd" <<EOF
#!/bin/sh
echo call >>"$work/bd.calls"
[ -e "$work/bd.fail" ] && exit 1
cat "$work/bd.json"
EOF
  chmod +x "$work/bin/gh" "$work/bin/bd"; export PATH="$work/bin:$PATH"
  echo '[]' >"$work/gh.json"
  printf '[{"id":"B1","status":"in_progress"},{"id":"B2","status":"in_progress"}]\n' >"$work/bd.json"
  cat >"$work/runtime.py" <<'PY'
import sys
rule = "─" * 80
box = rule + "\n❯ \n" + rule + "\n   ⏵⏵ bypass permissions on"
print("stub agent started", flush=True)
print(box, flush=True)
for line in sys.stdin:
    with open(sys.argv[1], "a") as inbox:
        inbox.write(line)
    print(box, flush=True)
PY
  start_lead() { # start_lead <name> <bead>: a live Lead in its own worktree, with no hook
    local name=$1 bead=$2 tree="$work/$1"
    git -C "$root" worktree add -q -b "feat/$name" "$tree" develop
    git -C "$tree" push -q -u origin "feat/$name"
    python3 - "$sessions/$name.json" "$name" "$bead" "$tree" "$root" <<'PY'
import json, re, sys
path, name, bead, tree, root = sys.argv[1:6]
json.dump({"name": name, "bead_id": bead, "role": "lead", "agent": "claude", "state": "running", "working_dir": root,
           "launch_prompt": "autonomous", "kickoff_sent_at": "2026-10-30T00:00:00+00:00",
           "started_at": "2026-10-30T00:00:00+00:00", "log_path": root + "/" + name + ".log"}, open(path, "w"))
record = "implementation--" + re.sub(r"[^a-z0-9-]", "-", bead.lower()) + ".json"
json.dump({"bead_id": bead, "path": tree}, open(root + "/.nogging/state/worktrees/" + record, "w"))
PY
    tmux -L "$sock" new-session -d -s "$name" -x 100 -y 12 "python3 $work/runtime.py $work/$name.inbox"
  }
  received() { [[ -f "$work/$1.inbox" ]] && wc -l <"$work/$1.inbox" | tr -d ' ' || echo 0; }
  settle() { # settle: age every remembered state and observation past its window
    python3 - "$root/.nogging/state" <<'PY'
import json, pathlib, sys
from datetime import datetime, timedelta, timezone
root = pathlib.Path(sys.argv[1])
old = (datetime.now(timezone.utc) - timedelta(minutes=5)).isoformat()
path = root / "dispatch/state.json"
state = json.loads(path.read_text())
for session in state["sessions"].values():
    session["since"] = old
    for slot in ("budget", "ci"):
        if session.get(slot, {}).get("last_nudge"):
            session[slot]["last_nudge"] = old
path.write_text(json.dumps(state))
for cache in (root / "sessions").glob("*.checks.json"):
    value = json.loads(cache.read_text())
    value["observation"]["observed_at"] = old
    cache.write_text(json.dumps(value))
PY
  }
  dispatch() { "$nogg" session dispatch "$@"; }
  until_prompt() { for _ in $(seq 1 50); do tmux -L "$sock" capture-pane -p -t "$1" | grep -q '❯' && return 0; sleep 0.1; done; return 1; }

  start_lead dirty-lead B1
  until_prompt dirty-lead && ok "integration: the stub agent is up on the private socket" || bad "integration: stub prompt never appeared"
  echo wip >"$work/dirty-lead/wip.txt"

  # A disabled config: nothing is read, written or sent.
  out=$(dispatch --once 2>&1) && ok "disabled: exits 0" || bad "disabled: failed: $out"
  case "$out" in *disabled*) ok "disabled: says so" ;; *) bad "disabled: no notice in: $out" ;; esac
  [[ ! -e "$root/.nogging/state/dispatch" && "$(received dirty-lead)" == 0 ]] && ok "disabled: no state and no message" || bad "disabled: something happened"
  expect "disabled: --json reports it" "False" "$(dispatch --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["enabled"])')"

  configure '{"session_dispatch": {"max_nudge": 2}}'
  out=$(dispatch --once 2>&1) && bad "config: a typo must refuse the pass" || ok "config: a typo refuses the pass"
  case "$out" in *max_nudge*) ok "config: the refusal names the key" ;; *) bad "config: refusal unclear: $out" ;; esac
  configure '{"session_dispatch": {"enabled": true}}'

  # The refusals of Decision 6.
  out=$(NOGG_SESSION_NAME=dirty-lead dispatch --once 2>&1) && bad "refusal: a supervised session must be refused" || ok "refusal: a supervised session is refused"
  case "$out" in *supervised*) ok "refusal: it says why" ;; *) bad "refusal: unclear: $out" ;; esac
  mkdir -p "$work/dirty-lead/.nogging"; cp "$root/.nogging/config.json" "$work/dirty-lead/.nogging/config.json"
  out=$(cd "$work/dirty-lead" && NOGGING_ROOT="$work/dirty-lead" "$nogg" session dispatch --dry-run 2>&1) \
    && bad "refusal: a linked worktree must be refused" || ok "refusal: a linked worktree is refused"
  case "$out" in *"main checkout"*) ok "refusal: it names the main checkout" ;; *) bad "refusal: unclear: $out" ;; esac
  rm -rf "$work/dirty-lead/.nogging"

  # A lock held elsewhere: exit 0 with nothing done.
  mkdir -p "$root/.nogging/locks"
  python3 -c "
import fcntl, sys, time
lock = open(sys.argv[1], 'a'); fcntl.flock(lock, fcntl.LOCK_EX); open(sys.argv[2], 'w').close(); time.sleep(30)" \
    "$root/.nogging/locks/dispatch.lock" "$work/locked" &
  holder=$!
  for _ in $(seq 1 50); do [[ -e "$work/locked" ]] && break; sleep 0.1; done
  out=$(dispatch --once 2>&1) && ok "lock: a busy lock exits 0" || bad "lock: busy lock failed: $out"
  case "$out" in *"holds the lock"*) ok "lock: says it is busy" ;; *) bad "lock: unclear: $out" ;; esac
  [[ ! -e "$root/.nogging/state/dispatch/state.json" ]] && ok "lock: a busy pass writes nothing" || bad "lock: a busy pass wrote state"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || true

  # A missed hook: no events file at all, and the first pass only starts the settle.
  [[ ! -e "$sessions/dirty-lead.events.jsonl" ]] && ok "hook: the session has no events" || bad "hook: fixture has events"
  dispatch --once >/dev/null
  expect "settle: the first pass sends nothing" "0" "$(received dirty-lead)"
  settle

  # --dry-run inside a supervised session reports and changes nothing.
  snapshot() { (cd "$root/.nogging/state" && find . -type f -not -name '*.lock' -exec sha256sum {} + | sort); }
  before=$(snapshot)
  out=$(NOGG_SESSION_NAME=dirty-lead dispatch --dry-run --json 2>&1) && ok "dry-run: allowed in a supervised session" || bad "dry-run: refused: $out"
  got=$(python3 -c "
import json, sys
print(','.join(a['type'] + ':' + a['reason'] + ':' + a['outcome'] for a in json.loads(sys.argv[1])['actions']))" "$out")
  expect "dry-run: reports the decided action" "nudge:gaps:dry-run" "$got"
  [[ "$before" == "$(snapshot)" ]] && ok "dry-run: wrote nothing" || bad "dry-run: state changed"
  expect "dry-run: sent nothing" "0" "$(received dirty-lead)"

  # The pass derives the gap from live state and git, with no hook.
  out=$(dispatch --once --json)
  got=$(python3 -c "
import json, sys
print(','.join(a['type'] + ':' + a['outcome'] for a in json.loads(sys.argv[1])['actions']))" "$out")
  expect "hook: a Lead whose hook never fired is still nudged" "nudge:done" "$got"
  for _ in $(seq 1 50); do [[ "$(received dirty-lead)" != 0 ]] && break; sleep 0.1; done
  expect "hook: the message reached the stub agent" "1" "$(received dirty-lead)"
  grep -q "uncommitted changes" "$work/dirty-lead.inbox" && ok "hook: the fixed text names the gap" || bad "hook: unexpected text: $(cat "$work/dirty-lead.inbox")"
  grep -q '"action": "nudge"' "$root/.nogging/state/dispatch/dispatch.jsonl" && ok "audit: the nudge is logged" || bad "audit: no row"

  # A replayed pass repeats nothing.
  dispatch --once >/dev/null; dispatch --once >/dev/null; sleep 0.3
  expect "replay: no second message" "1" "$(received dirty-lead)"

  # The budget runs out into one `stuck` item, and no third message.
  settle; dispatch --once >/dev/null
  for _ in $(seq 1 50); do [[ "$(received dirty-lead)" == 2 ]] && break; sleep 0.1; done
  settle; out=$(dispatch --once)
  settle; dispatch --once >/dev/null; sleep 0.3
  expect "stuck: no third message" "2" "$(received dirty-lead)"
  case "$out" in *"queued stuck dirty-lead"*) ok "stuck: session dispatch prints the item" ;; *) bad "stuck: no item in: $out" ;; esac
  expect "stuck: one item in queue.json" "stuck" \
    "$(python3 -c "import json,sys; print(','.join(i['kind'] for i in json.load(open(sys.argv[1]))['items']))" "$root/.nogging/state/dispatch/queue.json")"

  # Unknown evidence: gh and bd down, a clean Lead with no PR, and the pass still exits 0.
  start_lead clean-lead B2
  until_prompt clean-lead || bad "unknown: stub prompt never appeared"
  touch "$work/gh.fail" "$work/bd.fail"; rm -f "$root/.nogging/state/dispatch/beads.json"
  dispatch --once >/dev/null && ok "unknown: a pass with gh and bd down exits 0" || bad "unknown: the pass failed"
  settle
  dispatch --once >/dev/null && ok "unknown: the next pass exits 0 too" || bad "unknown: the second pass failed"
  sleep 0.3
  expect "unknown: nothing is inferred from a failure" "0" "$(received clean-lead)"
  rm -f "$work/gh.fail" "$work/bd.fail"

  # `gh` is throttled to one call in 120 s, and `bd` is read from its cache.
  settle; : >"$work/gh.calls"; : >"$work/bd.calls"
  dispatch --once >/dev/null
  for _ in $(seq 1 50); do [[ "$(received clean-lead)" != 0 ]] && break; sleep 0.1; done
  grep -q "session signal blocked" "$work/clean-lead.inbox" 2>/dev/null \
    && ok "evidence back: the clean Lead is told to open the PR or signal" || bad "evidence back: no nudge"
  dispatch --once >/dev/null; dispatch --once >/dev/null
  expect "throttle: gh ran once across three passes" "1" "$(wc -l <"$work/gh.calls" | tr -d ' ')"
  expect "throttle: bd ran once across three passes" "1" "$(wc -l <"$work/bd.calls" | tr -d ' ')"
fi

# --- shipped files ----------------------------------------------------------
# The installed consumer copy has no bin/ or package.json; check only where present.
for shipped in bin/lib/manifest.js package.json; do
  if [[ -f "$repo_root/$shipped" ]]; then
    grep -q "scripts/lib/session_dispatch.py" "$repo_root/$shipped" && ok "$shipped ships session_dispatch.py" || bad "$shipped misses session_dispatch.py"
  fi
done

[[ $fail -eq 0 ]] || { echo "session-dispatch: checks failed" >&2; exit 1; }
echo "session-dispatch: ok"
