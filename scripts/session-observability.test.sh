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
out=$(mktemp)
check() { # check <description> <expected-substring>  (greps the shared $out)
  if grep -qF -- "$2" "$out"; then ok "$1"; else bad "$1 (missing: $2)"; cat "$out"; fi
}
refute() { # refute <description> <substring-that-must-be-absent>  (greps $out)
  if grep -qF -- "$2" "$out"; then bad "$1 (present: $2)"; cat "$out"; else ok "$1"; fi
}

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
# TASK-SLK-005: `awaiting_manual_approval` narrows an idle Claude pane when
# the permission-mode status line reads manual mode; it never fires for
# Codex (no manual_mode pattern), and never overrides a non-idle state.
# ===========================================================================
got=$(printf 'some prior output\n⏸ manual mode on\n❯ \n' | classify claude)
[[ "$got" == "awaiting_manual_approval" ]] \
  && ok "claude: an idle pane showing '⏸ manual mode on' classifies awaiting_manual_approval" \
  || bad "claude: expected awaiting_manual_approval, got $got"

got=$(printf 'some prior output\n⏵⏵ auto mode on\n❯ \n' | classify claude)
[[ "$got" == "idle" ]] \
  && ok "claude: an idle pane showing auto mode stays plain idle" \
  || bad "claude: expected idle for auto mode, got $got"

got=$(printf '⏸ manual mode on\nesc to interrupt\n' | classify claude)
[[ "$got" == "working" ]] \
  && ok "claude: manual mode text never overrides a working classification" \
  || bad "claude: expected working regardless of manual-mode text, got $got"

got=$(printf '⏸ manual mode on\n> Ask Codex to do anything\n' | classify codex)
[[ "$got" == "idle" ]] \
  && ok "codex: has no manual_mode pattern, so 'manual mode on' text never triggers awaiting_manual_approval" \
  || bad "codex: expected plain idle, got $got"

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

# ===========================================================================
# TASK-SLK-002: pending_input_text() -- the shared pane-reading reader behind
# `nudge`, `send --verify`'s Claude branch, and `sweep`'s has-unsent-input.
# ===========================================================================
got=$(run_py "
m.session_pane_text = lambda name: 'some prior output\n❯ draft a reply and send it\n'
print(repr(m.pending_input_text('s1', 'claude')))
")
[[ "$got" == "'draft a reply and send it'" ]] \
  && ok "pending_input_text: strips the leading ❯ marker and returns the rest" \
  || bad "pending_input_text: expected the stripped text, got $got"

got=$(run_py "
m.session_pane_text = lambda name: 'some prior output\n❯ \n'
print(repr(m.pending_input_text('s1', 'claude')))
")
[[ "$got" == "''" ]] \
  && ok "pending_input_text: a bare ❯ prompt is empty" \
  || bad "pending_input_text: expected '', got $got"

got=$(run_py "
m.session_pane_text = lambda name: ''
print(repr(m.pending_input_text('s1', 'claude')))
")
[[ "$got" == "''" ]] \
  && ok "pending_input_text: an empty pane is empty" \
  || bad "pending_input_text: expected '' for an empty pane, got $got"

got=$(run_py "
m.session_pane_text = lambda name: 'some prior output\n❯ draft a reply\n'
print(m._pane_input_pending('s1', 'claude'))
")
[[ "$got" == "True" ]] \
  && ok "_pane_input_pending: Claude branch is now a real check, not the previous hardcoded False" \
  || bad "_pane_input_pending: expected True for pending Claude text, got $got"

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
trap 'rm -rf "$work"; rm -f "$out"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "show" ]]; then
  id="${2:-}"
  # TASK-SLK-004/006: a per-id fixture (with labels) takes priority over the
  # plain BD_KNOWN existence check every earlier test here already relies on.
  f="${BD_STUB_DIR:-/nonexistent}/show-$id.json"
  if [[ -f "$f" ]]; then cat "$f"; exit 0; fi
  for k in ${BD_KNOWN:-}; do
    if [[ "$k" == "$id" ]]; then printf '[{"id":"%s","title":"stub bead"}]\n' "$id"; exit 0; fi
  done
  echo '[]'; exit 1
fi
if [[ "${1:-}" == "list" ]]; then
  # TASK-SLK-006: `change_beads()` -- always dumps $BD_FIXTURE, like the
  # equivalent stub in scripts/nogg.test.sh.
  cat "${BD_FIXTURE:-/dev/null}" 2>/dev/null || echo '[]'
  exit 0
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

# ===========================================================================
# TASK-SOB-005: session send — literal paste + the claude second-Enter
# quirk, and --verify retrying the submit step once before failing loudly
# ===========================================================================
root="$work/send-claude"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/send-claude-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-s01"
"$nogg" session launch --role lead --bead SPEC-s01 >/dev/null 2>&1
name="$(sess_name "$root")"
: >"$TMUX_STUB_DIR/calls.log"
out_s=$(mktemp)
"$nogg" session send "$name" "continue please" >"$out_s" 2>&1 \
  || { echo "FAIL - send: errored"; cat "$out_s"; fail=1; }
grep -qF -- "send-keys -t $name -l continue please" "$TMUX_STUB_DIR/calls.log" \
  && ok "send: the literal message is pasted via send-keys -l" \
  || { echo "FAIL - send: literal paste not sent"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }
enter_count=$(grep -cF -- "send-keys -t $name Enter" "$TMUX_STUB_DIR/calls.log")
[[ "$enter_count" == "2" ]] \
  && ok "send: claude gets the second-bare-Enter quirk (2 Enters)" \
  || { echo "FAIL - send: expected 2 Enters for claude, got $enter_count"; fail=1; }
unset NOGGING_ROOT

root="$work/send-codex"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/send-codex-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-s02"
"$nogg" session launch --role lead --bead SPEC-s02 --agent codex --profile restricted >/dev/null 2>&1
name="$(sess_name "$root")"
printf '[Pasted Content]\n> Ask Codex to do anything\n' >"$TMUX_STUB_DIR/pane-$name.txt"
: >"$TMUX_STUB_DIR/calls.log"
"$nogg" session send "$name" "continue please" --verify >"$out_s" 2>&1 \
  && { echo "FAIL - send --verify: should have failed (message stays stuck)"; cat "$out_s"; fail=1; } \
  || ok "send --verify: raises when the message is still unsubmitted after a retry"
grep -qF "still unsubmitted after a retry" "$out_s" \
  && ok "send --verify: the error names the retry" \
  || { echo "FAIL - send --verify: unexpected error text"; cat "$out_s"; fail=1; }
submit_enters=$(grep -cF -- "send-keys -t $name Enter" "$TMUX_STUB_DIR/calls.log")
[[ "$submit_enters" == "2" ]] \
  && ok "send --verify: the submit step was retried exactly once" \
  || { echo "FAIL - send --verify: expected 2 submit attempts, got $submit_enters"; fail=1; }
rm -f "$out_s"
unset NOGGING_ROOT

# ===========================================================================
# TASK-SOB-006: codex queue --thread <uuid> resolves against a
# scripts/nogg-launched session (verified live against codex-cli 0.158.0) and
# becomes session send's primary path for --agent codex, with the Layer-1
# pane-based send-keys path skipped entirely. The thread id is discovered
# from Codex's own rollout-file `session_meta` header (no cold-start flag
# exists to pin it) and cached on the session record.
# ===========================================================================
root="$work/send-codex-queue"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/send-codex-queue-tmux"; mkdir -p "$TMUX_STUB_DIR"
export CODEX_HOME="$work/codex-home-queue"
export BD_KNOWN="SPEC-s03"
"$nogg" session launch --role lead --bead SPEC-s03 --agent codex --profile restricted >/dev/null 2>&1
name="$(sess_name "$root")"
cwd="$(python3 -c "import pathlib,sys; print(pathlib.Path(sys.argv[1]).resolve())" "$root")"
rollout_dir="$CODEX_HOME/sessions/2026/10/02"
mkdir -p "$rollout_dir"
thread_id="11111111-1111-1111-1111-111111111111"
ts="$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s","timestamp":"%s"}}\n' \
  "$thread_id" "$cwd" "$ts" >"$rollout_dir/rollout-2026-10-02T00-00-00-$thread_id.jsonl"

cat >"$work/bin/codex" <<STUB
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"$work/codex-queue-calls.log"
if [[ "\${1:-}" == "queue" ]]; then
  echo "Queued message fake-msg-id for thread \${3:-}."
  exit 0
fi
echo "stub codex: unexpected call: \$*" >&2
exit 1
STUB
chmod +x "$work/bin/codex"
: >"$work/codex-queue-calls.log"
: >"$TMUX_STUB_DIR/calls.log"

"$nogg" session send "$name" "continue please" --verify >"$out_s" 2>&1 \
  || { echo "FAIL - send (codex queue): errored"; cat "$out_s"; fail=1; }
grep -qF "sent to $name (codex queue)" "$out_s" \
  && ok "send: a resolvable codex thread uses codex queue as the primary path" \
  || { echo "FAIL - send: expected the codex-queue confirmation"; cat "$out_s"; fail=1; }
grep -qF -- "queue --thread $thread_id --message continue please" "$work/codex-queue-calls.log" \
  && ok "send: codex queue is invoked with the resolved thread id" \
  || { echo "FAIL - send: codex queue was not invoked as expected"; cat "$work/codex-queue-calls.log"; fail=1; }
! grep -qF "send-keys" "$TMUX_STUB_DIR/calls.log" \
  && ok "send: the Layer-1 pane-based send-keys path is skipped entirely" \
  || { echo "FAIL - send: expected no tmux send-keys calls"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }
grep -qF "\"codex_thread_id\": \"$thread_id\"" "$root/.nogging/state/sessions/$name.json" \
  && ok "send: the resolved thread id is cached on the session record" \
  || { echo "FAIL - send: codex_thread_id not cached on the session record"; fail=1; }
rm -f "$out_s" "$work/bin/codex"
unset NOGGING_ROOT CODEX_HOME

# ===========================================================================
# TASK-SOB-007: Claude Layer 2 (design.md Decision 4) — `session launch`
# wires Stop/Notification hooks into the per-session effective-settings file
# additively (no existing hook entry removed or reordered); `session emit
# <event>` appends one line to <name>.events.jsonl, keyed off
# NOGG_SESSION_NAME in the environment; `watch` prefers that file over
# pane-scraping for a Claude session once it has at least one line.
# ===========================================================================
root="$work/sob007-hooks"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/sob007-hooks-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-h01"
cat >"$work/preexisting-hooks-profile.json" <<'JSON'
{
  "permissions": {"defaultMode": "default", "deny": []},
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "echo pre-existing-stop"}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo guard"}]}]
  }
}
JSON
"$nogg" session launch --role lead --bead SPEC-h01 \
  --profile "$work/preexisting-hooks-profile.json" >/dev/null 2>&1
name="$(sess_name "$root")"
settings="$root/.nogging/state/sessions/$name.settings.json"
hook_check=$(python3 - "$settings" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
hooks = d.get("hooks", {})
stop = hooks.get("Stop", [])
notif = hooks.get("Notification", [])
pretool = hooks.get("PreToolUse", [])
ok = (
    len(stop) == 2
    and stop[0]["hooks"][0]["command"] == "echo pre-existing-stop"
    and stop[1]["hooks"][0]["command"] == "scripts/nogg session emit turn_end"
    and len(notif) == 1
    and notif[0]["hooks"][0]["command"] == "scripts/nogg session emit needs_input"
    and len(pretool) == 1
    and pretool[0]["hooks"][0]["command"] == "echo guard"
)
print("ok" if ok else "FAIL:" + json.dumps(hooks))
PY
)
[[ "$hook_check" == "ok" ]] \
  && ok "launch: Stop/Notification hooks appended, pre-existing Stop/PreToolUse hooks kept and not reordered" \
  || { echo "FAIL - launch: hook merge did not append as expected: $hook_check"; fail=1; }
unset NOGGING_ROOT

root="$work/sob007-emit"; make_obs_root "$root"
export NOGGING_ROOT="$root"
events_path="$root/.nogging/state/sessions/s1.events.jsonl"
mkdir -p "$(dirname "$events_path")"
got=$(NOGG_SESSION_NAME=s1 run_py "m.session_emit('turn_end')")
[[ -f "$events_path" ]] \
  && ok "emit: appends to <name>.events.jsonl" \
  || bad "emit: $events_path was not created"
grep -qF '"session": "s1"' "$events_path" && grep -qF '"event": "turn_end"' "$events_path" \
  && ok "emit: the line carries the session name (from the environment) and the event" \
  || { echo "FAIL - emit: unexpected line content"; cat "$events_path" 2>/dev/null; fail=1; }
got=$(run_py "
try:
    m.session_emit('turn_end')
    print('no-error')
except RuntimeError:
    print('raised')
")
[[ "$got" == "raised" ]] \
  && ok "emit: refuses without NOGG_SESSION_NAME set" \
  || bad "emit: expected a RuntimeError with no NOGG_SESSION_NAME, got $got"
unset NOGGING_ROOT

root="$work/sob007-watch-layer2"; make_obs_root "$root"
export NOGGING_ROOT="$root"
mkdir -p "$root/.nogging/state/sessions"
printf '{"timestamp":"2026-10-03T00:00:00Z","session":"s1","event":"turn_end"}\n' \
  >"$root/.nogging/state/sessions/s1.events.jsonl"
got=$(run_py "
m.tmux_sessions = lambda: {'s1'}
m.session_pane_text = lambda name: 'esc to interrupt'
print(m.classify_session({'name': 's1', 'agent': 'claude'})[0])
")
[[ "$got" == "idle" ]] \
  && ok "watch: a Claude session with a non-empty events file is classified via Layer 2 (idle), not the conflicting pane text" \
  || bad "watch: Layer-2-preferred classification was $got, expected idle"

printf '{"timestamp":"2026-10-03T00:00:01Z","session":"s1","event":"needs_input"}\n' \
  >>"$root/.nogging/state/sessions/s1.events.jsonl"
got=$(run_py "
m.tmux_sessions = lambda: {'s1'}
m.session_pane_text = lambda name: '> '
print(m.classify_session({'name': 's1', 'agent': 'claude'})[0])
")
[[ "$got" == "needs_input" ]] \
  && ok "watch: Layer 2 follows the most recent event (needs_input after turn_end)" \
  || bad "watch: expected needs_input from the latest event, got $got"

got=$(run_py "
m.tmux_sessions = lambda: {'s2'}
m.session_pane_text = lambda name: 'esc to interrupt'
print(m.classify_session({'name': 's2', 'agent': 'claude'})[0])
")
[[ "$got" == "working" ]] \
  && ok "watch: falls back to Layer 1 pane-scraping when the events file has no lines yet" \
  || bad "watch: expected Layer-1 fallback (working), got $got"
unset NOGGING_ROOT

# ===========================================================================
# TASK-SOB-004: resume-when-ready — waits out `limit`, dismisses a residual
# switch-model prompt without switching, then sends the resume instruction
# (classify_session/session_pane_text/session_send/tmux monkeypatched; pure)
# ===========================================================================
got=$(run_py "
m.time.sleep = lambda s: None
calls = {'n': 0}
def fake_classify(rec, live=None):
    calls['n'] += 1
    return ('limit', 'resets at 11:59pm') if calls['n'] == 1 else ('idle', '> ')
m.classify_session = fake_classify
m.load_session = lambda name: (None, {'name': name, 'agent': 'claude'})
m.session_pane_text = lambda name: '> '
sent = {}
m.session_send = lambda name, message, verify=False: sent.update(name=name, message=message, verify=verify)
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):
    m.session_resume_when_ready('s1')
print(sent['message'])
print(sent['verify'])
print(sent['name'])
")
expected_default=$(printf 'the usage limit has reset, continue exactly where you left off per your original instructions\nTrue\ns1')
[[ "$got" == "$expected_default" ]] \
  && ok "resume-when-ready: waits out limit then sends the default resume message with verify" \
  || bad "resume-when-ready: default-message run was: $got"

got=$(run_py "
m.time.sleep = lambda s: None
m.classify_session = lambda rec, live=None: ('idle', '> ')
m.load_session = lambda name: (None, {'name': name, 'agent': 'claude'})
m.session_pane_text = lambda name: '> '
sent = {}
m.session_send = lambda name, message, verify=False: sent.update(message=message)
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):
    m.session_resume_when_ready('s1', message='custom resume text')
print(sent['message'])
")
[[ "$got" == "custom resume text" ]] \
  && ok "resume-when-ready: --message overrides the default" \
  || bad "resume-when-ready: custom message run was: $got"

got=$(run_py "
m.time.sleep = lambda s: None
m.classify_session = lambda rec, live=None: ('idle', '> ')
m.load_session = lambda name: (None, {'name': name, 'agent': 'claude'})
m.session_pane_text = lambda name: 'Switch model? (y/n)'
tmux_calls = []
m.tmux = lambda *a, **k: tmux_calls.append(a)
m.session_send = lambda name, message, verify=False: None
import contextlib, io
with contextlib.redirect_stdout(io.StringIO()):
    m.session_resume_when_ready('s1')
print(any(call[-1] == 'Escape' for call in tmux_calls))
")
[[ "$got" == "True" ]] \
  && ok "resume-when-ready: dismisses a residual switch-model prompt (Escape, not a switch)" \
  || bad "resume-when-ready: switch-model dismissal run was: $got"

# ===========================================================================
# TASK-SLK-003: `session nudge` -- clears the pane (C-u) before sending
# anything; reads back pending text before clearing when no --message is
# given; refuses a non-running session with no tmux interaction at all.
# ===========================================================================
root="$work/nudge-claude"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/nudge-claude-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-n01"
"$nogg" session launch --role lead --bead SPEC-n01 >/dev/null 2>&1
name="$(sess_name "$root")"
out_n=$(mktemp)

printf 'previous turn output\n❯ draft a reply and send it\n' >"$TMUX_STUB_DIR/pane-$name.txt"
: >"$TMUX_STUB_DIR/calls.log"
"$nogg" session nudge "$name" >"$out_n" 2>&1 \
  || { echo "FAIL - nudge: errored"; cat "$out_n"; fail=1; }
grep -qF "nudged $name" "$out_n" \
  && ok "nudge: reports success" \
  || { echo "FAIL - nudge: missing success message"; cat "$out_n"; fail=1; }
cu_line=$(grep -nF -- "send-keys -t $name C-u" "$TMUX_STUB_DIR/calls.log" | head -1 | cut -d: -f1)
resend_line=$(grep -nF -- "send-keys -t $name -l draft a reply and send it" "$TMUX_STUB_DIR/calls.log" | head -1 | cut -d: -f1)
[[ -n "$cu_line" && -n "$resend_line" && "$cu_line" -lt "$resend_line" ]] \
  && ok "nudge: clears the pane (C-u) before resending the pending text" \
  || { echo "FAIL - nudge: C-u/resend ordering wrong"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }

printf 'previous turn output\n❯ \n' >"$TMUX_STUB_DIR/pane-$name.txt"
: >"$TMUX_STUB_DIR/calls.log"
"$nogg" session nudge "$name" >"$out_n" 2>&1 \
  || { echo "FAIL - nudge (empty): errored"; cat "$out_n"; fail=1; }
grep -qF "nothing to nudge" "$out_n" \
  && ok "nudge: an empty pane is reported as nothing to nudge" \
  || { echo "FAIL - nudge: expected nothing-to-nudge message"; cat "$out_n"; fail=1; }
grep -qF -- "send-keys -t $name C-u" "$TMUX_STUB_DIR/calls.log" \
  && ok "nudge: the C-u still runs on an empty pane" \
  || { echo "FAIL - nudge: C-u missing on empty-pane nudge"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }
! grep -qF -- "send-keys -t $name -l" "$TMUX_STUB_DIR/calls.log" \
  && ok "nudge: nothing further is sent when the pane was empty" \
  || { echo "FAIL - nudge: unexpected send-keys -l on an empty pane"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }

printf 'previous turn output\n❯ unrelated stale text\n' >"$TMUX_STUB_DIR/pane-$name.txt"
: >"$TMUX_STUB_DIR/calls.log"
"$nogg" session nudge "$name" --message "explicit override" >"$out_n" 2>&1 \
  || { echo "FAIL - nudge --message: errored"; cat "$out_n"; fail=1; }
grep -qF -- "send-keys -t $name -l explicit override" "$TMUX_STUB_DIR/calls.log" \
  && ok "nudge --message: overrides stale pane content" \
  || { echo "FAIL - nudge --message: expected message not sent"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }
! grep -qF -- "unrelated stale text" "$TMUX_STUB_DIR/calls.log" \
  && ok "nudge --message: the stale pane text is never sent" \
  || { echo "FAIL - nudge --message: stale text leaked into calls.log"; fail=1; }

python3 - "$root/.nogging/state/sessions/$name.json" <<'PY'
import json, sys
p = sys.argv[1]
rec = json.load(open(p))
rec['state'] = 'stopped'
json.dump(rec, open(p, 'w'))
PY
: >"$TMUX_STUB_DIR/calls.log"
"$nogg" session nudge "$name" >"$out_n" 2>&1 \
  && { echo "FAIL - nudge: should refuse a non-running session"; cat "$out_n"; fail=1; } \
  || ok "nudge: refuses a non-running session"
grep -qF "not running" "$out_n" \
  && ok "nudge: the refusal names the non-running state" \
  || { echo "FAIL - nudge: unexpected refusal text"; cat "$out_n"; fail=1; }
! grep -qF "send-keys" "$TMUX_STUB_DIR/calls.log" \
  && ok "nudge: refusing sends no tmux keys at all" \
  || { echo "FAIL - nudge: tmux was touched despite the refusal"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }
rm -f "$out_n"
unset NOGGING_ROOT

# ===========================================================================
# TASK-SLK-004: `session kickoff` -- verbatim with --message; composed from
# bead_id + openspec:change: label otherwise; refuses a non-running session
# and a bead-less session with no --message.
# ===========================================================================
root="$work/kickoff"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/kickoff-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_STUB_DIR="$work/kickoff-bd"; mkdir -p "$BD_STUB_DIR"
export BD_KNOWN="SPEC-k01"
printf '[{"id":"SPEC-k01","labels":["openspec:change:session-liveness-and-kickoff"]}]\n' \
  >"$BD_STUB_DIR/show-SPEC-k01.json"
"$nogg" session launch --role lead --bead SPEC-k01 >/dev/null 2>&1
name="$(sess_name "$root")"
out_k=$(mktemp)

: >"$TMUX_STUB_DIR/calls.log"
"$nogg" session kickoff "$name" --message "custom kickoff text" >"$out_k" 2>&1 \
  || { echo "FAIL - kickoff --message: errored"; cat "$out_k"; fail=1; }
grep -qF -- "send-keys -t $name -l custom kickoff text" "$TMUX_STUB_DIR/calls.log" \
  && ok "kickoff --message: sent verbatim" \
  || { echo "FAIL - kickoff --message: expected text not sent"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }

: >"$TMUX_STUB_DIR/calls.log"
"$nogg" session kickoff "$name" >"$out_k" 2>&1 \
  || { echo "FAIL - kickoff: errored"; cat "$out_k"; fail=1; }
grep -qF "SPEC-k01" "$TMUX_STUB_DIR/calls.log" \
  && grep -qF "session-liveness-and-kickoff" "$TMUX_STUB_DIR/calls.log" \
  && ok "kickoff: the composed message names the Bead and its change" \
  || { echo "FAIL - kickoff: composed message missing Bead/change"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }
grep -qF "tasks.md order" "$TMUX_STUB_DIR/calls.log" \
  && ok "kickoff: the composed message directs working tasks.md in order" \
  || { echo "FAIL - kickoff: composed message missing the tasks.md-order instruction"; fail=1; }

python3 - "$root/.nogging/state/sessions/$name.json" <<'PY'
import json, sys
p = sys.argv[1]
rec = json.load(open(p))
del rec['bead_id']
json.dump(rec, open(p, 'w'))
PY
: >"$TMUX_STUB_DIR/calls.log"
"$nogg" session kickoff "$name" >"$out_k" 2>&1 \
  && { echo "FAIL - kickoff: should refuse a bead-less session with no --message"; cat "$out_k"; fail=1; } \
  || ok "kickoff: refuses a bead-less session with no --message"
! grep -qF "send-keys" "$TMUX_STUB_DIR/calls.log" \
  && ok "kickoff: the bead-less refusal sends nothing" \
  || { echo "FAIL - kickoff: tmux was touched despite the refusal"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }

python3 - "$root/.nogging/state/sessions/$name.json" <<'PY'
import json, sys
p = sys.argv[1]
rec = json.load(open(p))
rec['state'] = 'stopped'
json.dump(rec, open(p, 'w'))
PY
: >"$TMUX_STUB_DIR/calls.log"
"$nogg" session kickoff "$name" --message "doesn't matter" >"$out_k" 2>&1 \
  && { echo "FAIL - kickoff: should refuse a non-running session"; cat "$out_k"; fail=1; } \
  || ok "kickoff: refuses a non-running session even with --message"
! grep -qF "send-keys" "$TMUX_STUB_DIR/calls.log" \
  && ok "kickoff: the non-running refusal sends nothing" \
  || { echo "FAIL - kickoff: tmux was touched despite the refusal"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }
rm -f "$out_k"
unset NOGGING_ROOT BD_STUB_DIR

# ===========================================================================
# TASK-SLK-004: `session launch --kickoff` chains kickoff immediately after a
# successful launch; a bare launch instead names the missing step.
# ===========================================================================
root="$work/launch-kickoff"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/launch-kickoff-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_STUB_DIR="$work/launch-kickoff-bd"; mkdir -p "$BD_STUB_DIR"
export BD_KNOWN="SPEC-lk1"
printf '[{"id":"SPEC-lk1","labels":["openspec:change:session-liveness-and-kickoff"]}]\n' \
  >"$BD_STUB_DIR/show-SPEC-lk1.json"
"$nogg" session launch --role lead --bead SPEC-lk1 --kickoff >"$out" 2>&1 \
  || { echo "FAIL - launch --kickoff: errored"; cat "$out"; fail=1; }
name="$(sess_name "$root")"
grep -qF "SPEC-lk1" "$TMUX_STUB_DIR/calls.log" 2>/dev/null \
  && ok "launch --kickoff: the first message is already delivered by the time launch returns" \
  || { echo "FAIL - launch --kickoff: no kickoff message found in tmux calls"; cat "$TMUX_STUB_DIR/calls.log" 2>/dev/null; fail=1; }
refute "launch --kickoff: the missing-kickoff-step line is not printed" \
  "this session will not act until you send it a first message"
unset NOGGING_ROOT BD_STUB_DIR

root="$work/launch-bare"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/launch-bare-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-lb1"
"$nogg" session launch --role lead --bead SPEC-lb1 >"$out" 2>&1 \
  || { echo "FAIL - launch (bare): errored"; cat "$out"; fail=1; }
check "launch (bare): names the missing kickoff step and the exact follow-up command" \
  "this session will not act until you send it a first message"
unset NOGGING_ROOT

# ===========================================================================
# TASK-SLK-005: the launch-time manual/restricted-mode warning fires for a
# bare lead/specialist launch, is suppressed by an explicit profile/prompt/
# full-access, and never fires for --role orchestrator.
# ===========================================================================
root="$work/launch-warn-lead"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/launch-warn-lead-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-lw1"
"$nogg" session launch --role lead --bead SPEC-lw1 >"$out" 2>&1 \
  || { echo "FAIL - launch-warn: bare lead launch errored"; cat "$out"; fail=1; }
check "launch-warn: a bare lead launch prints the restricted/manual-mode warning" \
  "launched in restricted/manual mode"
unset NOGGING_ROOT

root="$work/launch-warn-full"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/launch-warn-full-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-lw2"
"$nogg" session launch --role lead --bead SPEC-lw2 --full-access >"$out" 2>&1 \
  || { echo "FAIL - launch-warn: --full-access launch errored"; cat "$out"; fail=1; }
refute "launch-warn: --full-access suppresses the warning" "launched in restricted/manual mode"
unset NOGGING_ROOT

root="$work/launch-warn-orc"; make_obs_root "$root"
export NOGGING_ROOT="$root"
export TMUX_STUB_DIR="$work/launch-warn-orc-tmux"; mkdir -p "$TMUX_STUB_DIR"
"$nogg" session launch --role orchestrator >"$out" 2>&1 \
  || { echo "FAIL - launch-warn: orchestrator launch errored"; cat "$out"; fail=1; }
refute "launch-warn: --role orchestrator never warns" "launched in restricted/manual mode"
unset NOGGING_ROOT

# ===========================================================================
# TASK-SLK-006: `session sweep` classification (pure, bd/tmux/pending-text/
# idle-duration monkeypatched) against fixture Beads data.
# ===========================================================================
got=$(run_py "
import contextlib, io
m.session_records = lambda: [
    (None, {'name': 'sess-complete', 'bead_id': 'B1', 'agent': 'claude', 'state': 'running'}),
]
m.tmux_sessions = lambda: {'sess-complete'}
m.bead_change = lambda bead_id: 'demo-change'
m.change_beads = lambda change: [{'id': 'B1', 'status': 'closed'}]
m._session_worktree_branch = lambda rec: 'feat/demo'
m._pr_state_for_branch = lambda branch: 'MERGED'
m.pending_input_text = lambda name, agent: ''
m._idle_minutes = lambda rec: 5
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    m.session_sweep()
print(buf.getvalue().strip())
")
[[ "$got" == "sess-complete: change-complete  has-unsent-input=no  idle for 5m" ]] \
  && ok "sweep: every Bead closed + a merged PR reports change-complete" \
  || bad "sweep: change-complete line was: $got"

got=$(run_py "
import contextlib, io
m.session_records = lambda: [
    (None, {'name': 'sess-blocked', 'bead_id': 'B2', 'agent': 'claude', 'state': 'running'}),
]
m.tmux_sessions = lambda: {'sess-blocked'}
m.bead_change = lambda bead_id: 'demo-change'
m.change_beads = lambda change: [{'id': 'B2', 'status': 'open'}, {'id': 'B3', 'status': 'blocked'}]
m.pending_input_text = lambda name, agent: 'draft text'
m._idle_minutes = lambda rec: None
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    m.session_sweep()
print(buf.getvalue().strip())
")
[[ "$got" == "sess-blocked: bead-blocked (B3)  has-unsent-input=yes  idle for unknown" ]] \
  && ok "sweep: a blocked sibling Bead reports bead-blocked, naming it" \
  || bad "sweep: bead-blocked line was: $got"

got=$(run_py "
import contextlib, io
m.session_records = lambda: [
    (None, {'name': 'sess-active', 'bead_id': 'B4', 'agent': 'claude', 'state': 'running'}),
    (None, {'name': 'sess-orc', 'bead_id': None, 'agent': 'claude', 'state': 'running'}),
]
m.tmux_sessions = lambda: {'sess-active', 'sess-orc'}
m.bead_change = lambda bead_id: 'demo-change'
m.change_beads = lambda change: [{'id': 'B4', 'status': 'open'}]
m.pending_input_text = lambda name, agent: ''
m._idle_minutes = lambda rec: 1
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    m.session_sweep()
print(buf.getvalue().strip())
")
[[ "$got" == "sess-active: active  has-unsent-input=no  idle for 1m" ]] \
  && ok "sweep: open unblocked Beads report active, and a bead-less session is skipped entirely" \
  || bad "sweep: active line was: $got"

# ===========================================================================
# TASK-SLK-007: `doctor` surfaces exactly the three flagged states (reusing
# the same classification, no shell-out) and nothing else for an active,
# unflagged session.
# ===========================================================================
root="$work/doctor-sweep"; make_obs_root "$root"
export NOGGING_ROOT="$root"
got=$(run_py "
import contextlib, io
m.session_records = lambda: [
    (None, {'name': 'sess-complete', 'bead_id': 'B1', 'agent': 'claude', 'state': 'running'}),
    (None, {'name': 'sess-blocked', 'bead_id': 'B2', 'agent': 'claude', 'state': 'running'}),
    (None, {'name': 'sess-manual', 'bead_id': 'B3', 'agent': 'claude', 'state': 'running'}),
    (None, {'name': 'sess-active', 'bead_id': 'B4', 'agent': 'claude', 'state': 'running'}),
]
m.tmux_sessions = lambda: {'sess-complete', 'sess-blocked', 'sess-manual', 'sess-active'}
def fake_change_beads(change):
    return {
        'demo-complete': [{'id': 'B1', 'status': 'closed'}],
        'demo-blocked': [{'id': 'B2', 'status': 'open'}, {'id': 'B5', 'status': 'blocked'}],
        'demo-manual': [{'id': 'B3', 'status': 'open'}],
        'demo-active': [{'id': 'B4', 'status': 'open'}],
    }[change]
m.change_beads = fake_change_beads
m.bead_change = lambda bead_id: {
    'B1': 'demo-complete', 'B2': 'demo-blocked', 'B3': 'demo-manual', 'B4': 'demo-active',
}[bead_id]
m._session_worktree_branch = lambda rec: None
m._pr_state_for_branch = lambda branch: None
def fake_classify_session(rec, live=None):
    if rec['name'] == 'sess-manual':
        return ('awaiting_manual_approval', '')
    return ('idle', '')
m.classify_session = fake_classify_session
m.recover_scan = lambda: ([], [])
m.validate = lambda: ({}, [], [], [])
m.boundary_state_line = lambda: 'openspec write boundary: LOCKED'
m.tool_on_path = lambda name: name in ('git', 'python3', 'bd', 'dolt')
m.archive_ready_changes = lambda tasks, issues: []
m.persona_mismatch_notes = lambda: []
m.multi_machine_enabled = lambda: False
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    m.doctor()
for line in buf.getvalue().splitlines():
    if line.startswith('NOTE  session '):
        print(line)
")
want_doctor=$(printf 'NOTE  session sess-complete: change-complete\nNOTE  session sess-blocked: bead-blocked (B5)\nNOTE  session sess-manual: awaiting_manual_approval (idle in manual mode; needs a human to approve each step)')
[[ "$got" == "$want_doctor" ]] \
  && ok "doctor: surfaces exactly change-complete, bead-blocked, and awaiting_manual_approval, nothing for the active session" \
  || bad "doctor: session NOTE lines were: $got"
unset NOGGING_ROOT

if [[ $fail -ne 0 ]]; then
  echo "session-observability: FAILED" >&2
  exit 1
fi
echo "session-observability: all checks passed"
