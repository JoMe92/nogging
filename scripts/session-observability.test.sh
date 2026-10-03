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

if [[ $fail -ne 0 ]]; then
  echo "session-observability: FAILED" >&2
  exit 1
fi
echo "session-observability: all checks passed"
