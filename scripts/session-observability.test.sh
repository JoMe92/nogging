#!/usr/bin/env bash
# Regression checks for the session-observability capability
# (openspec/changes/session-observability).
#
# TASK-SOB-001: the `Adapter` data shape and the `claude` / `codex` pattern
# tables, classified via fixture pane captures — no live agent required.
# Covers the `Auto-update failed` false-positive regression explicitly.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

classify() {
  # classify <adapter> <pane-text-stdin>
  PANE_TEXT="$(cat)" python3 - "$nogg" "$1" <<'PY'
import os, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_sob_classify", sys.argv[1]).load_module()
adapter = m.ADAPTERS[sys.argv[2]]
pane = os.environ["PANE_TEXT"]
print(m.classify(pane, adapter))
PY
}

# ===========================================================================
# claude adapter fixtures
# ===========================================================================
got=$(printf 'some output above\nesc to interrupt\n' | classify claude)
[[ "$got" == "working" ]] && ok "claude: 'esc to interrupt' classifies working" \
  || bad "claude: expected working, got $got"

got=$(printf '2 shells still running\n' | classify claude)
[[ "$got" == "waiting_background" ]] && ok "claude: background shells classify waiting_background" \
  || bad "claude: expected waiting_background, got $got"

got=$(printf 'Do you want to proceed?\n❯ 1. Yes\n' | classify claude)
[[ "$got" == "needs_input" ]] && ok "claude: permission prompt classifies needs_input" \
  || bad "claude: expected needs_input, got $got"

got=$(printf 'Claude usage limit reached. Your limit will reset at 3:30pm.\n' | classify claude)
[[ "$got" == "limit" ]] && ok "claude: usage-limit banner classifies limit" \
  || bad "claude: expected limit, got $got"

got=$(printf 'some prior output\n❯ \n' | classify claude)
[[ "$got" == "idle" ]] && ok "claude: a bare prompt classifies idle" \
  || bad "claude: expected idle, got $got"

got=$(printf 'nothing recognizable here\n' | classify claude)
[[ "$got" == "unknown" ]] && ok "claude: unrecognized pane text classifies unknown" \
  || bad "claude: expected unknown, got $got"

# --- the regression case this change exists to fix -----------------------
got=$(printf 'Auto-update failed: no write permission to npm prefix\n3 shells still running\n' | classify claude)
[[ "$got" == "waiting_background" ]] \
  && ok "claude: Auto-update failed banner + background shells is waiting_background, not unknown" \
  || bad "claude: expected waiting_background (Auto-update regression), got $got"

got=$(printf 'Auto-update failed: no write permission to npm prefix\n' | classify claude)
[[ "$got" == "unknown" ]] \
  && ok "claude: Auto-update failed banner alone (nothing else happening) is unknown, not a false 'attention' state" \
  || bad "claude: expected unknown with only the ignored banner present, got $got"

# ===========================================================================
# codex adapter fixtures
# ===========================================================================
got=$(printf 'Working (12s · esc to interrupt)\n' | classify codex)
[[ "$got" == "working" ]] && ok "codex: 'Working (' classifies working" \
  || bad "codex: expected working, got $got"

got=$(printf '> Ask Codex to do anything\n' | classify codex)
[[ "$got" == "idle" ]] && ok "codex: idle prompt classifies idle" \
  || bad "codex: expected idle, got $got"

got=$(printf '[Pasted Content]\n> Ask Codex to do anything\n' | classify codex)
[[ "$got" == "needs_input" ]] \
  && ok "codex: undelivered_input (Pasted Content) outranks an idle-looking pane" \
  || bad "codex: expected needs_input, got $got"

# ===========================================================================
# TASK-SOB-002: duration parsing (pure) + watch_poll_once transition/stall
# semantics (pure, classify_session/tmux_sessions/load_session monkeypatched)
# ===========================================================================
run_py() {
  python3 - "$nogg" <<PY
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_sob_watch", sys.argv[1]).load_module()
$1
PY
}

got=$(run_py "print(m.parse_duration('30'))")
[[ "$got" == "30.0" ]] && ok "parse_duration: bare seconds" || bad "parse_duration('30') = $got"
got=$(run_py "print(m.parse_duration('15m'))")
[[ "$got" == "900.0" ]] && ok "parse_duration: minutes" || bad "parse_duration('15m') = $got"
got=$(run_py "print(m.parse_duration('2h'))")
[[ "$got" == "7200.0" ]] && ok "parse_duration: hours" || bad "parse_duration('2h') = $got"
got=$(run_py "
try:
    m.parse_duration('nope')
    print('no-error')
except RuntimeError:
    print('raised')
")
[[ "$got" == "raised" ]] && ok "parse_duration: garbage input raises" || bad "parse_duration('nope') = $got"

logf="$(mktemp)"
events=$(NOGG_TEST_LOG="$logf" run_py "
import contextlib, io, json, os
log = os.environ['NOGG_TEST_LOG']
m.tmux_sessions = lambda: {'s1'}
m.load_session = lambda name: (None, {'name': 's1', 'log_path': log})
m.classify_session = lambda rec, live=None: ('working', '')
tracked = {'s1': {'state': None, 'stalled': False}}
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    m.watch_poll_once(tracked, 9999, 'jsonl')   # 1st poll: state None->working, emits
    m.watch_poll_once(tracked, 9999, 'jsonl')   # 2nd poll: unchanged, no stall yet -> no event
for line in buf.getvalue().splitlines():
    print(json.loads(line)['event'])
")
[[ "$(echo "$events" | tr '\n' ,)" == "working," ]] \
  && ok "watch_poll_once: exactly one event for a steady-state session" \
  || bad "watch_poll_once: steady-state events were: $events"

touch -d '@0' "$logf" 2>/dev/null || touch -t 197001010000 "$logf"   # age the log
events2=$(NOGG_TEST_LOG="$logf" run_py "
import contextlib, io, json, os
log = os.environ['NOGG_TEST_LOG']
m.tmux_sessions = lambda: {'s1'}
m.load_session = lambda name: (None, {'name': 's1', 'log_path': log})
m.classify_session = lambda rec, live=None: ('working', '')
tracked = {'s1': {'state': 'working', 'stalled': False}}
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    m.watch_poll_once(tracked, 1, 'jsonl')   # log is ancient -> stalled, emitted once
    m.watch_poll_once(tracked, 1, 'jsonl')   # still stalled -> not repeated
for line in buf.getvalue().splitlines():
    print(json.loads(line)['event'])
")
[[ "$(echo "$events2" | tr '\n' ,)" == "stalled," ]] \
  && ok "watch_poll_once: a stalled working session is reported exactly once" \
  || bad "watch_poll_once: stall events were: $events2"
rm -f "$logf"

# ===========================================================================
# TASK-SOB-002 CLI-level checks: a stateful tmux + bd stub (same technique as
# scripts/session.test.sh), plus a `capture-pane` fixture file per session
# (`pane-<name>.txt`) this suite controls directly.
# ===========================================================================
work=$(mktemp -d)
repo_root="$(cd "$here/.." && pwd)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "show" ]]; then
  id="${2:-}"
  for k in ${BD_KNOWN:-}; do
    if [[ "$k" == "$id" ]]; then printf '[{"id":"%s","title":"stub bead"}]\n' "$id"; exit 0; fi
  done
  echo '[]'; exit 1
fi
echo "stub bd: unexpected call in session-observability tests: $*" >&2
exit 1
STUB
chmod +x "$work/bin/bd"

cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-L" ]] && shift 2
cmd="${1:-}"; shift || true
d="${TMUX_STUB_DIR:?TMUX_STUB_DIR unset}"; mkdir -p "$d"
printf '%s %s\n' "$cmd" "$*" >>"$d/calls.log"
arg_after() { local flag="$1"; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$flag" ]] && { printf '%s' "$2"; return; }; shift; done; }
case "$cmd" in
  new-session)
    name="$(arg_after -s "$@")"; touch "$d/sess-$name" ;;
  has-session)
    name="$(arg_after -t "$@")"; [[ -f "$d/sess-$name" ]] ;;
  list-sessions)
    for f in "$d"/sess-*; do [[ -e "$f" ]] || continue; echo "${f##*/sess-}"; done ;;
  capture-pane)
    name="$(arg_after -t "$@")"
    cat "$d/pane-$name.txt" 2>/dev/null || true ;;
  kill-session)
    name="$(arg_after -t "$@")"; rm -f "$d/sess-$name" ;;
  kill-server) rm -f "$d"/sess-* ;;
  send-keys|pipe-pane|attach|display-message) : ;;
  *) : ;;
esac
STUB
chmod +x "$work/bin/tmux"

export PATH="$work/bin:$PATH"

make_obs_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state"
  cp "$repo_root/.nogging/config.json" "$r/.nogging/"
  cp -r "$repo_root/.nogging/launch-profiles" "$r/.nogging/" 2>/dev/null || true
  cp -r "$repo_root/.nogging/launch-prompts" "$r/.nogging/" 2>/dev/null || true
}
sess_name() { ls "$1/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//'; }

root="$work/watch-working"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/watch-working-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-w01"
"$nogg" session launch --role lead --bead SPEC-w01 >/dev/null 2>&1
name="$(sess_name "$root")"
printf 'some prior output\nesc to interrupt\n' >"$TMUX_STUB_DIR/pane-$name.txt"
out_w=$(mktemp)
"$nogg" session watch "$name" --once --format jsonl >"$out_w" 2>&1
grep -qF '"event": "working"' "$out_w" \
  && ok "watch --once: a working pane emits a working event" \
  || { echo "FAIL - watch --once: expected a working event"; cat "$out_w"; fail=1; }
grep -qF "\"session\": \"$name\"" "$out_w" \
  && ok "watch --once: the event names the session" \
  || { echo "FAIL - watch --once: session name missing"; cat "$out_w"; fail=1; }

rm -f "$TMUX_STUB_DIR/sess-$name"
"$nogg" session watch "$name" --once --format jsonl >"$out_w" 2>&1
grep -qF '"event": "ended"' "$out_w" \
  && ok "watch --once: a gone tmux session reports ended" \
  || { echo "FAIL - watch --once: expected ended"; cat "$out_w"; fail=1; }
rm -f "$out_w"
unset NOGGING_ROOT

# ===========================================================================
# TASK-SOB-003: usage-limit timestamp resolution (pure) + watch's until=
# ===========================================================================
got=$(run_py "
import datetime as dt
now = dt.datetime(2026, 10, 2, 14, 0, 0)
print(m.resolve_clock_time('reset at 3:30pm', now=now))
")
[[ "$got" == "2026-10-02T15:30:00" ]] \
  && ok "resolve_clock_time: same-day reset resolves to today" \
  || bad "resolve_clock_time same-day = $got"

got=$(run_py "
import datetime as dt
now = dt.datetime(2026, 10, 2, 23, 0, 0)
print(m.resolve_clock_time('reset at 1:00am', now=now))
")
[[ "$got" == "2026-10-03T01:00:00" ]] \
  && ok "resolve_clock_time: overnight reset rolls to the next day" \
  || bad "resolve_clock_time overnight = $got"

got=$(run_py "print(m.resolve_clock_time('nothing resembling a time here'))")
[[ "$got" == "None" ]] && ok "resolve_clock_time: no time token found returns None" \
  || bad "resolve_clock_time no-match = $got"

root="$work/watch-limit"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/watch-limit-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-w02"
"$nogg" session launch --role lead --bead SPEC-w02 >/dev/null 2>&1
name="$(sess_name "$root")"
printf 'Claude usage limit reached. Your limit will reset at 11:59pm.\n' >"$TMUX_STUB_DIR/pane-$name.txt"
out_w2=$(mktemp)
"$nogg" session watch "$name" --once --format jsonl >"$out_w2" 2>&1
grep -qF '"event": "limit"' "$out_w2" \
  && ok "watch --once: a usage-limit banner classifies limit" \
  || { echo "FAIL - watch --once: expected limit"; cat "$out_w2"; fail=1; }
grep -qE '"until": "[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$out_w2" \
  && ok "watch --once: the limit event carries a resolved until= timestamp" \
  || { echo "FAIL - watch --once: no resolved until= timestamp"; cat "$out_w2"; fail=1; }
rm -f "$out_w2"
unset NOGGING_ROOT

docgrep() {
  grep -qi "switching models does not clear" "$1" \
    && ok "docs: $1 carries the switching-models-does-not-clear-this note" \
    || bad "docs: $1 is missing the switching-models note"
}
docgrep "$repo_root/docs/failure-recovery.md"
docgrep "$repo_root/docs/using-with-codex.md"

if [[ $fail -ne 0 ]]; then
  echo "session-observability: FAILED" >&2
  exit 1
fi
echo "session-observability: all checks passed"
