#!/usr/bin/env bash
# TASK-SWK-001 (openspec/changes/session-wake): the normalized lifecycle stream,
# `session signal`, the Codex rollout reader and one evidence order. Offline:
# committed hook payloads and rollout excerpts, no live agent.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; use_agent_stubs

while IFS= read -r inherited; do
  case "$inherited" in
    NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_*) unset "$inherited" ;;
  esac
done < <(compgen -e)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
nogg="$here/nogg"
fx="$here/fixtures/session-signals"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
expect() { # expect <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 (expected: $2, got: $3)"; fi
}

# --- unit tests of the pure modules (source-only; an installed consumer skips) --
for unit in session_signals_test.py session_codex_delivery_test.py; do
  if [[ -f "$here/lib/$unit" ]]; then
    python3 "$here/lib/$unit" >"$work/unit.out" 2>&1 && ok "scripts/lib/$unit" || { bad "scripts/lib/$unit"; cat "$work/unit.out"; }
  else
    ok "$unit skipped (installed consumer copy)"
  fi
done

root="$work/root"
mkdir -p "$root/.nogging/state/sessions" "$root/scripts"
git init -q "$root"
copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
events="$root/.nogging/state/sessions/s1.events.jsonl"
export NOGGING_ROOT="$root"

emit() { # emit <event> [stdin-file]   (session s1, agent from $AGENT)
  local ev="$1" in="${2:-/dev/null}"
  NOGG_SESSION_NAME=s1 NOGG_SESSION_AGENT="${AGENT:-claude}" "$nogg" session emit "$ev" <"$in"
}
last() { python3 -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(json.dumps(rows[-1]) if rows else '')" "$events"; }
field() { python3 -c "import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2]))" "$1" "$2"; }
run_py() {
  python3 - "$nogg" <<PY
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_swk001", sys.argv[1]).load_module()
$1
PY
}

# --- the normalized event ---------------------------------------------------
emit turn_end "$fx/claude-stop.json"
row=$(last)
expect "emit: schema 2" "2" "$(field "$row" schema)"
expect "emit: source names the runtime hook" "claude-hook" "$(field "$row" source)"
keys=$(python3 -c "import json,sys; print(','.join(sorted(json.loads(sys.argv[1]))))" "$row")
expect "emit: only whitelisted fields are kept" \
  "background_tasks,error,event,excerpt,notification_type,schema,session,source,timestamp" "$keys"
excerpt=$(field "$row" excerpt)
case "$excerpt" in *owner@example.com*|*sk-test-not-a-real-key*|*unknown_field*) bad "emit: excerpt leaks: $excerpt" ;; *) ok "emit: excerpt drops the email and the secret assignment" ;; esac
case "$excerpt" in *PR\ \#321\ is\ open*) ok "emit: excerpt keeps the message, on one line" ;; *) bad "emit: excerpt lost the message: $excerpt" ;; esac
[[ "$excerpt" != *$'\n'* && "$excerpt" != *$'\a'* ]] && ok "emit: excerpt is single-line and control-free" || bad "emit: excerpt has control characters"

python3 -c "print('{\"last_assistant_message\": \"' + 'x'*5000 + '\"}')" >"$work/long.json"
emit turn_end "$work/long.json"
expect "emit: excerpt is at most 300 characters" "True" \
  "$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])['excerpt'])<=300)" "$(last)")"

printf 'this is {not json' >"$work/junk.json"
emit turn_end "$work/junk.json" && ok "emit: junk stdin exits 0" || bad "emit: junk stdin failed"
row=$(last)
expect "emit: junk stdin still records the event" "turn_end" "$(field "$row" event)"
expect "emit: junk stdin leaves the excerpt empty" "None" "$(field "$row" excerpt)"

python3 -c "print('{\"error\": \"x\", \"pad\": \"' + 'y'*200000 + '\"}')" >"$work/huge.json"
emit turn_end "$work/huge.json" && ok "emit: an oversized payload is bounded and tolerated" || bad "emit: oversized payload failed"
expect "emit: an oversized payload is truncated into junk, not parsed" "None" "$(field "$(last)" error)"

before=$(wc -l <"$events")
emit needs_input "$fx/claude-notification-idle.json"
expect "emit: an idle_prompt notification records nothing" "$before" "$(wc -l <"$events")"
emit needs_input "$fx/claude-notification-permission.json"
row=$(last)
expect "emit: a permission_prompt notification is needs_input" "needs_input" "$(field "$row" event)"
expect "emit: the notification type is passed through" "permission_prompt" "$(field "$row" notification_type)"
emit needs_input && expect "emit: a bare needs_input (no payload) is still recorded" "needs_input" "$(field "$(last)" event)"

# --- rotation ---------------------------------------------------------------
rm -f "$events" "$events.1"
python3 -c "print('{\"event\":\"turn_end\",\"pad\":\"' + 'z'*262144 + '\"}')" >"$events"
emit turn_start
expect "rotate: a 256 KiB file is rotated before the append" "turn_start" "$(field "$(last)" event)"
[[ "$(wc -l <"$events")" == 1 && -s "$events.1" ]] && ok "rotate: the old events are kept in .1 and the new file starts fresh" || bad "rotate: rotation did not happen"
rm -f "$events" "$events.1"

# --- classification: Claude -------------------------------------------------
cls() { # cls <agent> <pane-text> [rollout-fixture]
  PANE="$2" ROLLOUT="${3:-}" python3 - "$nogg" "$1" <<'PY'
import os, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_swk001c", sys.argv[1]).load_module()
m.tmux_sessions = lambda: {"s1"}
m.session_pane_text = lambda name, escapes=False: os.environ["PANE"]
if os.environ["ROLLOUT"]:
    m.resolve_codex_thread_id = lambda rec, merge=False: "thread-0001"
    m._codex_rollout_path = lambda thread, cwd: os.environ["ROLLOUT"]
detail = m.classify_session_detail({"name": "s1", "agent": sys.argv[2], "working_dir": "/scratch/work"})
print(detail["state"], detail["source"], detail.get("excerpt") or "")
PY
}
set_events() { rm -f "$events"; for e in "$@"; do emit "$e" >/dev/null; done; }

set_events turn_start turn_end
read -r state source _ <<<"$(cls claude '❯ ')"
expect "classify: a turn_end event is idle" "idle event" "$state $source"
set_events turn_start turn_end turn_start
read -r state source _ <<<"$(cls claude '❯ ')"
expect "classify: a later turn_start is working, not idle" "working event" "$state $source"
set_events turn_start turn_end
read -r state source _ <<<"$(cls claude 'esc to interrupt')"
expect "classify: an idle event yields to a live working pane (lost start hook)" "working pane" "$state $source"
rm -f "$events"; emit turn_end "$fx/claude-stop-background.json"
read -r state source _ <<<"$(cls claude '❯ ')"
expect "classify: a Stop with a running background task is waiting_background" "waiting_background event" "$state $source"
rm -f "$events"; emit turn_error "$fx/claude-stop-failure.json"
read -r state source _ <<<"$(cls claude '❯ ')"
expect "classify: a rate_limit turn_error is limit" "limit event" "$state $source"
rm -f "$events"; emit turn_error
read -r state source _ <<<"$(cls claude '❯ ')"
expect "classify: any other turn_error is idle" "idle event" "$state $source"
set_events turn_start session_end
read -r state source _ <<<"$(cls claude '❯ ')"
expect "classify: session_end is ended" "ended event" "$state $source"
rm -f "$events"; emit needs_input "$fx/claude-notification-permission.json"
read -r state source _ <<<"$(cls claude $'Do you want to proceed?\n❯ 1. Yes')"
expect "classify: a live permission prompt stays needs_input" "needs_input pane" "$state $source"
read -r state source _ <<<"$(cls claude 'esc to interrupt')"
expect "classify: a stale needs_input yields to live working evidence" "working pane" "$state $source"

# --- classification: Pi and unknown ----------------------------------------
AGENT=pi; set_events turn_start turn_end
read -r state source _ <<<"$(cls pi '')"
expect "classify: a Pi session with turn_end is idle, not unknown" "idle event" "$state $source"
rm -f "$events"
read -r state source _ <<<"$(cls pi '')"
expect "classify: no evidence at all stays unknown" "unknown none" "$state $source"
AGENT=claude

# --- classification: Codex rollout -----------------------------------------
rm -f "$events"
read -r state source excerpt <<<"$(cls codex '› ' "$fx/codex-rollout-complete.jsonl")"
expect "classify: a finished Codex turn needs no hook" "idle rollout" "$state $source"
expect "classify: the rollout excerpt is exposed, single-line" "Opened PR #321. CI is running." "$(cls codex '› ' "$fx/codex-rollout-complete.jsonl" | cut -d' ' -f3-)"
read -r state source _ <<<"$(cls codex '› ' "$fx/codex-rollout-aborted.jsonl")"
expect "classify: a terminal abort is idle" "idle rollout" "$state $source"
read -r state source _ <<<"$(cls codex 'Working (3s)' "$fx/codex-rollout-unknown.jsonl")"
expect "classify: an unknown rollout falls through to the pane adapter" "working pane" "$state $source"
read -r state source _ <<<"$(cls codex '› ' "$fx/codex-rollout-unknown.jsonl")"
[[ "$source" != rollout ]] && ok "classify: an unrecognized rollout is never read as finished" || bad "classify: unknown rollout read as $state"
python3 - "$repo_root/scripts/lib" "$fx" <<'PY' && ok "reader: last_turn reports the end kind, message and abort reason" || bad "reader: last_turn"
import sys
sys.path.insert(0, sys.argv[1])
import session_codex_delivery as r
done = r.last_turn(sys.argv[2] + "/codex-rollout-complete.jsonl")
assert (done["state"], done["end"]) == ("idle", "task_complete"), done
assert done["message"].startswith("Opened PR #321"), done
aborted = r.last_turn(sys.argv[2] + "/codex-rollout-aborted.jsonl")
assert (aborted["end"], aborted["reason"]) == ("aborted", "interrupted"), aborted
assert r.last_turn(sys.argv[2] + "/codex-rollout-unknown.jsonl")["state"] == "none"
assert r.last_turn(sys.argv[2] + "/missing.jsonl")["state"] == "none"
assert r.turn_state(sys.argv[2] + "/codex-rollout-complete.jsonl") == "idle"
PY

# --- Antigravity is untouched ----------------------------------------------
grep -q "def antigravity_stop_event" "$nogg" && ok "antigravity: the Stop path function is still present" || bad "antigravity: path removed"

# --- session signal ---------------------------------------------------------
rm -f "$events"
set_events turn_start turn_end
out=$(NOGG_SESSION_NAME=s1 NOGG_SESSION_AGENT=claude "$nogg" session signal blocked "worktree rebase refused: needs owner@example.com" 2>&1) \
  && ok "signal: blocked exits 0" || bad "signal: blocked failed: $out"
row=$(last)
expect "signal: appends a blocked event" "blocked" "$(field "$row" event)"
expect "signal: the reason is the redacted excerpt" "worktree rebase refused: needs ***EMAIL***" "$(field "$row" excerpt)"
case "$out" in *"dispatch is on"*) ok "signal: a config with no key says dispatch is on" ;; *) bad "signal: no dispatch status in: $out" ;; esac
read -r state source _ <<<"$(cls claude '❯ ')"
expect "signal: a blocked signal does not change the classified state" "idle event" "$state $source"
NOGG_SESSION_NAME=s1 "$nogg" session signal done "PR #321 open" >/dev/null && expect "signal: done is recorded" "done" "$(field "$(last)" event)"
if "$nogg" session signal done "x" >"$work/nosession.out" 2>&1; then bad "signal: must refuse outside a supervised session"; else
  grep -q "NOGG_SESSION_NAME" "$work/nosession.out" && ok "signal: refuses outside a supervised session, naming why" || bad "signal: refusal unclear: $(cat "$work/nosession.out")"; fi
NOGG_SESSION_NAME=s1 "$nogg" session signal maybe "x" >/dev/null 2>&1 && bad "signal: accepted an unknown kind" || ok "signal: refuses an unknown kind"
NOGG_SESSION_NAME=s1 "$nogg" session signal done >/dev/null 2>&1 && bad "signal: accepted no reason" || ok "signal: requires a reason"
long=$(python3 -c "print('r'*600)")
NOGG_SESSION_NAME=s1 "$nogg" session signal done "$long" >/dev/null
expect "signal: the reason is limited to 300 characters" "True" \
  "$(python3 -c "import json,sys; print(len(json.loads(sys.argv[1])['excerpt'])<=300)" "$(last)")"
out=$(PATH="$work/nobin:/usr/bin:/bin" NOGG_SESSION_NAME=s1 "$nogg" session signal done "needs neither bd nor network" 2>&1) \
  && ok "signal: works with no bd, no Dolt and no network" || bad "signal: needed a service: $out"
cp "$root/.nogging/config.json" "$work/config.kept"
edit_dispatch() { python3 -c '
import json, sys
config = json.load(open(sys.argv[1])); config["session_dispatch"] = json.loads(sys.argv[2])
json.dump(config, open(sys.argv[1], "w"))' "$root/.nogging/config.json" "$1"; }
edit_dispatch '{"enabled": false}'
out=$(NOGG_SESSION_NAME=s1 "$nogg" session signal done "PR #321 open" 2>&1)
case "$out" in *"dispatch is off"*"Wait for CI yourself"*) ok "signal: an explicit false says dispatch is off" ;; *) bad "signal: unclear: $out" ;; esac
edit_dispatch '{"stall_after": "soon"}'
out=$(NOGG_SESSION_NAME=s1 "$nogg" session signal done "PR #321 open" 2>&1) \
  && ok "signal: a config validate refuses costs no signal" || bad "signal: a bad block failed it: $out"
case "$out" in *"dispatch is on"*) ok "signal: and it still says dispatch is on" ;; *) bad "signal: unclear: $out" ;; esac
cp "$work/config.kept" "$root/.nogging/config.json"

# --- watch reports a signal as its own event --------------------------------
rm -f "$events"; set_events turn_start turn_end
NOGG_SESSION_NAME=s1 "$nogg" session signal done "PR #321 open" >/dev/null
out=$(run_py "
import json
m.tmux_sessions = lambda: {'s1'}
m.session_pane_text = lambda name, escapes=False: '❯ '
m.load_session = lambda name: (None, {'name': 's1', 'agent': 'claude', 'state': 'running'})
m.refresh_session_usage = lambda running: None
tracked = {'s1': {'state': None, 'stalled': False}}
m.watch_poll_once(tracked, 900, 'jsonl')
m.watch_poll_once(tracked, 900, 'jsonl')
")
python3 - "$out" <<'PY' && ok "watch: the signal is its own event, reported once, beside the unchanged idle state" || bad "watch: $out"
import json, sys
rows = [json.loads(l) for l in sys.argv[1].splitlines() if l.startswith("{")]
events = [r["event"] for r in rows]
assert events == ["idle", "done"], events
assert rows[1]["reason"] == "PR #321 open", rows
PY

# --- hooks wired into the effective settings --------------------------------
got=$(run_py "
import json
out = m.merge_observability_hooks({'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': 'echo user'}]}]}})
hooks = out['hooks']
print(json.dumps({k: [h['hooks'][0]['command'].split(' session emit ')[-1] for h in v] for k, v in hooks.items()}, sort_keys=True))
")
expect "hooks: UserPromptSubmit, StopFailure and SessionEnd are wired, SubagentStop is not" \
  '{"Notification": ["needs_input"], "SessionEnd": ["session_end"], "Stop": ["echo user", "turn_end --guard"], "StopFailure": ["turn_error"], "UserPromptSubmit": ["turn_start"]}' "$got"

got=$(run_py "
once = m.merge_signal_permission({'permissions': {'allow': ['Read(src/**)']}})
twice = m.merge_signal_permission(once)
print(once['permissions']['allow'], twice == once)
")
expect "permissions: session signal is appended once, existing rules kept" \
  "['Read(src/**)', 'Bash(./scripts/nogg session signal:*)'] True" "$got"
grep -qF 'if role_meta == "lead":' "$nogg" && ok "permissions: the launch adds the signal rule for a Lead" || bad "permissions: launch does not add the rule"

# --- shipped files ----------------------------------------------------------
# The installed consumer copy has no bin/ or package.json; check only where present.
for shipped in bin/lib/manifest.js package.json; do
  if [[ -f "$repo_root/$shipped" ]]; then
    grep -q "scripts/lib/session_signals.py" "$repo_root/$shipped" && ok "$shipped ships session_signals.py" || bad "$shipped misses session_signals.py"
  fi
done
[[ -f "$here/lib/session_signals.py" ]] && ok "session_signals.py sits beside scripts/nogg" || bad "session_signals.py is missing from scripts/lib"

[[ $fail -eq 0 ]] || { echo "session-signals: checks failed" >&2; exit 1; }
echo "session-signals: ok"
