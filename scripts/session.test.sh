#!/usr/bin/env bash
# Regression checks for `scripts/nogg session ...` (TASK-SESSION-013).
#
# tmux is STUBBED (PATH-injected, same technique as the `bd` stub and the
# SPECFORGE_ROOT seam in scripts/nogg.test.sh): no real tmux server is
# ever started. The stub is stateful — `new-session` creates a marker file,
# `kill-session` / a C-c `send-keys` removes it, `has-session` / `list-sessions`
# read it — so lifecycle transitions are observable without a tty.
#
# Covered:
#   - launch writes the metadata record AND the log file before it execs tmux;
#   - a name collision is rejected and nothing existing is overwritten;
#   - `list` reports a vanished active session as `failed`;
#   - `stop` records a terminal state and is idempotent;
#   - `cleanup` refuses a running record and succeeds on a stopped one;
#   - `launch` performs no `bd` mutation;
#   - a seeded secret value reaches neither the recorded command nor the log;
#   - the append-only log writer rotates by size to the configured depth.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
specforge="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

# --- stubs -----------------------------------------------------------------
mkdir -p "$work/bin"

# bd: `show <id> --json` returns a record for any id under $BD_KNOWN (space
# separated); every other call is logged to $BD_MUTATION_LOG and fails.
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
printf 'bd %s\n' "$*" >>"${BD_MUTATION_LOG:-/dev/null}"
echo "stub bd: refusing mutation in session tests: $*" >&2
exit 1
STUB
chmod +x "$work/bin/bd"

# tmux: stateful stub over $TMUX_STUB_DIR.
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
    name="$(arg_after -s "$@")"
    # metadata AND log must already exist on disk before the child is exec'd
    ls "$SPECFORGE_ROOT"/.nogging/state/sessions/*.json >/dev/null 2>&1 \
      || { echo "tmux stub: no metadata record before exec" >&2; exit 90; }
    ls "$SPECFORGE_ROOT"/.nogging/state/sessions/*.log  >/dev/null 2>&1 \
      || { echo "tmux stub: no log file before exec" >&2; exit 91; }
    touch "$d/sess-$name" ;;
  has-session)
    [[ -n "${TMUX_STUB_ALL_COLLIDE:-}" ]] && exit 0
    name="$(arg_after -t "$@")"; [[ -f "$d/sess-$name" ]] ;;
  list-sessions)
    for f in "$d"/sess-*; do [[ -e "$f" ]] || continue; echo "${f##*/sess-}"; done ;;
  send-keys)
    name="$(arg_after -t "$@")"
    [[ -z "${TMUX_STUB_IGNORE_SIGINT:-}" ]] && rm -f "$d/sess-$name" ;;
  kill-session)
    name="$(arg_after -t "$@")"; rm -f "$d/sess-$name" ;;
  kill-server) rm -f "$d"/sess-* ;;
  pipe-pane|attach) : ;;
  *) : ;;
esac
STUB
chmod +x "$work/bin/tmux"

export PATH="$work/bin:$PATH"

fail=0
check() { if grep -qF -- "$2" "$out"; then echo "ok   - $1"; else echo "FAIL - $1 (missing: $2)"; cat "$out"; fail=1; fi; }
refute() { if grep -qF -- "$2" "$out"; then echo "FAIL - $1 (present: $2)"; cat "$out"; fail=1; else echo "ok   - $1"; fi; }

# make_root <dir> [grace] — minimal SpecForge checkout for the session layer.
make_root() {
  local r="$1" grace="${2:-10}"
  mkdir -p "$r/.nogging/state"
  # the launch profile / prompt files the bridge resolves and now reads
  cp "$repo_root/.nogging/session-launch-profile.json" "$r/.nogging/" 2>/dev/null || true
  cp "$repo_root/.nogging/session-launch-prompt.md" "$r/.nogging/" 2>/dev/null || true
  cp -r "$repo_root/.nogging/launch-profiles" "$r/.nogging/" 2>/dev/null || true
  cp -r "$repo_root/.nogging/launch-prompts" "$r/.nogging/" 2>/dev/null || true
  python3 - "$repo_root/.nogging/config.json" "$r/.nogging/config.json" "$grace" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["session_stop_grace_seconds"] = float(sys.argv[3])
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
}
record() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"; }

# ===========================================================================
# Scenario: launch writes metadata + log before exec, and no bd mutation
# ===========================================================================
root="$work/launch"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/launch-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-aaa"
export BD_MUTATION_LOG="$work/launch-bd-mutations.log"; : >"$BD_MUTATION_LOG"

"$specforge" session launch --role lead --bead SPEC-aaa >"$out" 2>&1 \
  || { echo "FAIL - launch: errored"; cat "$out"; fail=1; }
check "launch: reports the created session" "launched sf-lead-spec-aaa-"
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
[[ -f "$root/.nogging/state/sessions/$name.json" ]] \
  && echo "ok   - launch: metadata record written" \
  || { echo "FAIL - launch: no metadata record"; fail=1; }
[[ -f "$root/.nogging/state/sessions/$name.log" ]] \
  && echo "ok   - launch: append-only log written" \
  || { echo "FAIL - launch: no log file"; fail=1; }
# the tmux stub's new-session aborts (exit 90/91) if either is missing at exec
grep -qF "new-session " "$TMUX_STUB_DIR/calls.log" \
  && echo "ok   - launch: tmux new-session reached with metadata+log already on disk" \
  || { echo "FAIL - launch: new-session not called"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }
grep -qF "pipe-pane " "$TMUX_STUB_DIR/calls.log" \
  && echo "ok   - launch: pipe-pane log stream started" \
  || { echo "FAIL - launch: pipe-pane not called"; fail=1; }
[[ "$(record "$root/.nogging/state/sessions/$name.json" state)" == "running" ]] \
  && echo "ok   - launch: record ends in running state" \
  || { echo "FAIL - launch: state not running"; fail=1; }
[[ -s "$BD_MUTATION_LOG" ]] \
  && { echo "FAIL - launch: a bd mutation was attempted"; cat "$BD_MUTATION_LOG"; fail=1; } \
  || echo "ok   - launch: no bd mutation (only the read-only bd show)"
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: a name collision is rejected without overwriting anything
# ===========================================================================
root="$work/collide"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/collide-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-bbb"
mkdir -p "$root/.nogging/state/sessions"
printf '{"name":"pre-existing","state":"running","bead_id":"SPEC-bbb"}\n' \
  >"$root/.nogging/state/sessions/keeper.json"
sum_before="$(cksum <"$root/.nogging/state/sessions/keeper.json")"
TMUX_STUB_ALL_COLLIDE=1 "$specforge" session launch --role lead --bead SPEC-bbb >"$out" 2>&1 \
  && { echo "FAIL - collide: launch should have failed"; fail=1; } \
  || echo "ok   - collide: launch refused when every candidate name collides"
check "collide: message says nothing was reused or overwritten" "reused or overwritten"
[[ "$(cksum <"$root/.nogging/state/sessions/keeper.json")" == "$sum_before" ]] \
  && echo "ok   - collide: the pre-existing record was not overwritten" \
  || { echo "FAIL - collide: pre-existing record changed"; fail=1; }
[[ "$(ls "$root/.nogging/state/sessions" | wc -l)" == "1" ]] \
  && echo "ok   - collide: no new record was created" \
  || { echo "FAIL - collide: extra records created"; ls "$root/.nogging/state/sessions"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: list reports a vanished active session as failed
# ===========================================================================
root="$work/list"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/list-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-ccc"
"$specforge" session launch --role specialist:backend-engineer --bead SPEC-ccc >/dev/null 2>&1
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
"$specforge" session list >"$out" 2>&1
check "list: a live session shows its real state" "running"
check "list: shows the Bead id" "SPEC-ccc"
check "list: shows the role" "specialist:backend-engineer"
rm -f "$TMUX_STUB_DIR"/sess-*        # the tmux session vanishes behind specforge's back
env -u TERM "$specforge" session list >"$out" 2>&1
check "list: vanished active session reported as failed" "failed"
refute "list: vanished session no longer reported as running" "running"
[[ "$(record "$root/.nogging/state/sessions/$name.json" state)" == "running" ]] \
  && echo "ok   - list: reconciliation did not rewrite the on-disk record" \
  || { echo "FAIL - list: list mutated the record"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: stop records a terminal state and is idempotent
# ===========================================================================
root="$work/stop"; make_root "$root" 0.2
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/stop-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-ddd"
"$specforge" session launch --role lead --bead SPEC-ddd >/dev/null 2>&1
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"

"$specforge" session stop "$name" --reason "operator asked" >"$out" 2>&1 \
  || { echo "FAIL - stop: errored"; cat "$out"; fail=1; }
[[ "$(record "$rec" state)" == "stopped" ]] \
  && echo "ok   - stop: record is in the stopped terminal state" \
  || { echo "FAIL - stop: state not stopped"; fail=1; }
[[ "$(record "$rec" exit_reason)" == "operator asked" ]] \
  && echo "ok   - stop: exit_reason recorded" || { echo "FAIL - stop: no exit_reason"; fail=1; }
[[ "$(record "$rec" ended_at)" != "None" ]] \
  && echo "ok   - stop: ended_at recorded" || { echo "FAIL - stop: no ended_at"; fail=1; }
ended_first="$(record "$rec" ended_at)"
"$specforge" session stop "$name" >"$out" 2>&1 \
  || { echo "FAIL - stop: second stop errored"; cat "$out"; fail=1; }
check "stop: second stop is a reported no-op" "nothing to do"
[[ "$(record "$rec" ended_at)" == "$ended_first" ]] \
  && echo "ok   - stop: idempotent — ended_at unchanged on the second call" \
  || { echo "FAIL - stop: ended_at moved on re-stop"; fail=1; }

# stop also drives the kill path when the child ignores the interrupt
root2="$work/stop-kill"; make_root "$root2" 0.2
export SPECFORGE_ROOT="$root2"
export TMUX_STUB_DIR="$work/stop-kill-tmux"; mkdir -p "$TMUX_STUB_DIR"
"$specforge" session launch --role lead --bead SPEC-ddd >/dev/null 2>&1
name2="$(ls "$root2/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
TMUX_STUB_IGNORE_SIGINT=1 "$specforge" session stop "$name2" >"$out" 2>&1
grep -qF "kill-session " "$TMUX_STUB_DIR/calls.log" \
  && echo "ok   - stop: escalates to kill-session after the grace period" \
  || { echo "FAIL - stop: no kill-session escalation"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }
[[ "$(record "$root2/.nogging/state/sessions/$name2.json" state)" == "stopped" ]] \
  && echo "ok   - stop: terminal state recorded even when the child ignored C-c" \
  || { echo "FAIL - stop: state not stopped after kill"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: cleanup refuses a running record, succeeds on a stopped one
# ===========================================================================
root="$work/cleanup"; make_root "$root" 0.2
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/cleanup-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-eee"
"$specforge" session launch --role lead --bead SPEC-eee >/dev/null 2>&1
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"

"$specforge" session cleanup "$name" >"$out" 2>&1 \
  && { echo "FAIL - cleanup: should refuse a running record"; fail=1; } \
  || echo "ok   - cleanup: refuses a running record"
check "cleanup: tells the operator to stop it first" "stop"
[[ "$(record "$rec" state)" == "running" ]] \
  && echo "ok   - cleanup: running record left untouched" \
  || { echo "FAIL - cleanup: running record changed"; fail=1; }

"$specforge" session stop "$name" >/dev/null 2>&1
"$specforge" session cleanup "$name" >"$out" 2>&1 \
  || { echo "FAIL - cleanup: errored on a stopped record"; cat "$out"; fail=1; }
check "cleanup: retires the stopped record" "retired $name"
[[ "$(record "$rec" state)" == "retired" ]] \
  && echo "ok   - cleanup: record marked retired" || { echo "FAIL - cleanup: not retired"; fail=1; }
ls "$root/.nogging/state/sessions/$name.log" >/dev/null 2>&1 \
  && { echo "FAIL - cleanup: active log not archived"; fail=1; } \
  || echo "ok   - cleanup: active log archive-rotated away"
ls "$root/.nogging/state/sessions/$name.log".archived-* >/dev/null 2>&1 \
  && echo "ok   - cleanup: archived log kept under an archived name" \
  || { echo "FAIL - cleanup: no archived log"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: session reap moves a vanished active record to failed (TASK-RIR-011)
# ===========================================================================
root="$work/reap"; make_root "$root" 0.2
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/reap-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-rp1"
"$specforge" session launch --role lead --bead SPEC-rp1 >/dev/null 2>&1
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"
rm -f "$TMUX_STUB_DIR"/sess-*        # the tmux session vanishes behind specforge's back
"$specforge" session reap >"$out" 2>&1 \
  || { echo "FAIL - reap: errored"; cat "$out"; fail=1; }
check "reap: reports the vanished session" "reaped 1 vanished session"
[[ "$(record "$rec" state)" == "failed" ]] \
  && echo "ok   - reap: the vanished record is now failed" \
  || { echo "FAIL - reap: state is $(record "$rec" state)"; fail=1; }
[[ "$(record "$rec" exit_reason)" == "tmux session vanished during a reap" ]] \
  && echo "ok   - reap: exit_reason records the reap" \
  || { echo "FAIL - reap: exit_reason is $(record "$rec" exit_reason)"; fail=1; }
"$specforge" session reap >"$out" 2>&1 || true
check "reap: a second reap finds nothing" "no vanished active sessions to reap"
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: reap -> cleanup retires the crashed record; a live one is untouched
# (TASK-RIR-014)
# ===========================================================================
root="$work/reapclean"; make_root "$root" 0.2
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/reapclean-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-rc1 SPEC-rc2"
"$specforge" session launch --role lead --bead SPEC-rc1 >/dev/null 2>&1
"$specforge" session launch --role lead --bead SPEC-rc2 >/dev/null 2>&1
pick() { ls "$root/.nogging/state/sessions" | grep "^sf-lead-spec-$1-" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//'; }
dead="$(pick rc1)"
live="$(pick rc2)"
deadrec="$root/.nogging/state/sessions/$dead.json"
liverec="$root/.nogging/state/sessions/$live.json"

rm -f "$TMUX_STUB_DIR/sess-$dead"        # only the first session's tmux vanishes
"$specforge" session reap >"$out" 2>&1 || { echo "FAIL - reapclean: reap errored"; cat "$out"; fail=1; }
check "reapclean: reap names only the vanished session" "reaped 1 vanished session(s): $dead"
[[ "$(record "$deadrec" state)" == "failed" ]] \
  && echo "ok   - reapclean: the vanished record is failed" \
  || { echo "FAIL - reapclean: dead state is $(record "$deadrec" state)"; fail=1; }
[[ "$(record "$liverec" state)" == "running" ]] \
  && echo "ok   - reapclean: the live record is left running by reap" \
  || { echo "FAIL - reapclean: live state is $(record "$liverec" state)"; fail=1; }

"$specforge" session cleanup >"$out" 2>&1 || { echo "FAIL - reapclean: cleanup errored"; cat "$out"; fail=1; }
check "reapclean: cleanup retires the reaped record" "retired $dead"
[[ "$(record "$deadrec" state)" == "retired" ]] \
  && echo "ok   - reapclean: reaped record now retired" \
  || { echo "FAIL - reapclean: dead state is $(record "$deadrec" state)"; fail=1; }
[[ "$(record "$liverec" state)" == "running" ]] \
  && echo "ok   - reapclean: the live record is still running after cleanup" \
  || { echo "FAIL - reapclean: live state is $(record "$liverec" state)"; fail=1; }
[[ -f "$TMUX_STUB_DIR/sess-$live" ]] \
  && echo "ok   - reapclean: the live tmux session was not touched" \
  || { echo "FAIL - reapclean: live tmux session killed"; fail=1; }
ls "$root/.nogging/state/sessions/$live.log" >/dev/null 2>&1 \
  && echo "ok   - reapclean: the live session's active log is intact" \
  || { echo "FAIL - reapclean: live log archived away"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: a seeded secret reaches neither the recorded command nor the log
# ===========================================================================
root="$work/secret"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/secret-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-fff"
export ANTHROPIC_API_KEY="sk-secret-DO-NOT-LEAK-12345"
export GH_TOKEN="ghp-secret-DO-NOT-LEAK-67890"
"$specforge" session launch --role lead --bead SPEC-fff >/dev/null 2>&1
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
cp "$root/.nogging/state/sessions/$name.json" "$out"
refute "secret: ANTHROPIC_API_KEY value absent from the recorded command" "sk-secret-DO-NOT-LEAK-12345"
refute "secret: GH_TOKEN value absent from the recorded command" "ghp-secret-DO-NOT-LEAK-67890"
cp "$root/.nogging/state/sessions/$name.log" "$out"
refute "secret: ANTHROPIC_API_KEY value absent from the log" "sk-secret-DO-NOT-LEAK-12345"
refute "secret: GH_TOKEN value absent from the log" "ghp-secret-DO-NOT-LEAK-67890"
# the redactor genuinely scrubs a secret value that does land in the argv
out2=$(python3 - "$repo_root/scripts/nogg" <<'PY'
import os, sys
from importlib.machinery import SourceFileLoader
os.environ["EVIL_TOKEN"] = "zzz-super-secret-value"
m = SourceFileLoader("sf_under_test", sys.argv[1]).load_module()
print(m.redact("claude --key zzz-super-secret-value --go"))
PY
)
[[ "$out2" == "claude --key ***REDACTED*** --go" ]] \
  && echo "ok   - secret: redact() replaces a secret-named env value in argv" \
  || { echo "FAIL - secret: redact() did not scrub ($out2)"; fail=1; }
unset SPECFORGE_ROOT ANTHROPIC_API_KEY GH_TOKEN

# ===========================================================================
# Scenario: the append-only log writer rotates by size to the configured depth
# ===========================================================================
writer="$here/session-log-writer"
lg="$work/rot.log"
printf 'line-aaaaaaaaaa\nline-bbbbbbbbbb\nline-cccccccccc\nline-dddddddddd\n' \
  | "$writer" "$lg" 20 2
[[ -f "$lg" && -f "$lg.1" && -f "$lg.2" ]] \
  && echo "ok   - log-writer: rotates the active log and keeps depth files" \
  || { echo "FAIL - log-writer: rotation files missing"; ls "$work"; fail=1; }
[[ ! -f "$lg.3" ]] \
  && echo "ok   - log-writer: nothing kept past the configured depth" \
  || { echo "FAIL - log-writer: depth exceeded"; fail=1; }

# ===========================================================================
# Scenario: no-flag launch stays restricted + the no-autonomous-claim prompt
# ===========================================================================
root="$work/lp-default"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/lp-default-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-lp1"
"$specforge" session launch --role lead --bead SPEC-lp1 >"$out" 2>&1 \
  || { echo "FAIL - lp-default: launch errored"; cat "$out"; fail=1; }
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"
eff="$(record "$rec" effective_settings_path)"
[[ -f "$eff" ]] \
  && echo "ok   - lp-default: per-session effective-settings file written" \
  || { echo "FAIL - lp-default: no effective-settings file"; fail=1; }
grep -qF -- "--settings $eff" "$TMUX_STUB_DIR/calls.log" \
  && echo "ok   - lp-default: effective-settings path passed as --settings" \
  || { echo "FAIL - lp-default: --settings is not the effective file"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }
grep -qE -- "--prompt [^ ]*/no-autonomous-claim\.md" "$TMUX_STUB_DIR/calls.log" \
  && echo "ok   - lp-default: no-autonomous-claim prompt passed" \
  || { echo "FAIL - lp-default: default prompt not passed"; fail=1; }
[[ "$(record "$rec" profile)" == "restricted" ]] \
  && echo "ok   - lp-default: record profile is restricted" \
  || { echo "FAIL - lp-default: record profile is $(record "$rec" profile)"; fail=1; }
cp "$eff" "$out"
check "lp-default: keeps the restricted defaultMode" '"defaultMode": "default"'
refute "lp-default: grants nothing extra (no allow list)" '"allow"'
diff -q "$root/.nogging/launch-profiles/restricted.json" \
        "$repo_root/.nogging/launch-profiles/restricted.json" >/dev/null \
  && echo "ok   - lp-default: source profile left unmutated" \
  || { echo "FAIL - lp-default: source profile changed"; fail=1; }
# TASK-TWB-004: a non-planning launch with no fresh planning lock gets openspec/
# as a read-only root in its effective authority.
check "twb-launch: effective settings deny an Edit under openspec/"  'Edit(openspec/**)'
check "twb-launch: effective settings deny a Write under openspec/"  'Write(openspec/**)'
[[ "$(record "$rec" openspec_readonly)" == "True" ]] \
  && echo "ok   - twb-launch: record marks openspec_readonly true for an execution launch" \
  || { echo "FAIL - twb-launch: openspec_readonly is $(record "$rec" openspec_readonly)"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: a launch during a fresh planning session keeps openspec/ writable
# (TASK-TWB-004). The read-only root keys off the session's role + the planning
# lock, not the sentinel.
# ===========================================================================
root="$work/twb-planning"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/twb-planning-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-twp"
mkdir -p "$root/.nogging/locks"
printf '{"pid":1,"host":"h","created_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
  >"$root/.nogging/locks/planning.lock"
"$specforge" session launch --role lead --bead SPEC-twp >"$out" 2>&1 \
  || { echo "FAIL - twb-planning: launch errored"; cat "$out"; fail=1; }
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"
cp "$(record "$rec" effective_settings_path)" "$out"
refute "twb-planning: no openspec deny while a fresh planning lock is held" 'Edit(openspec/**)'
[[ "$(record "$rec" openspec_readonly)" == "False" ]] \
  && echo "ok   - twb-planning: record marks openspec_readonly false during planning" \
  || { echo "FAIL - twb-planning: openspec_readonly is $(record "$rec" openspec_readonly)"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: a named profile resolves; the floor is unioned in; list shows it
# ===========================================================================
root="$work/lp-named"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/lp-named-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-lp2"
"$specforge" session launch --role lead --bead SPEC-lp2 --profile trusted --prompt autonomous >"$out" 2>&1 \
  || { echo "FAIL - lp-named: launch errored"; cat "$out"; fail=1; }
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"
eff="$(record "$rec" effective_settings_path)"
cp "$eff" "$out"
check "lp-named: trusted defaultMode carried through" '"defaultMode": "acceptEdits"'
check "lp-named: trusted still allows git push" 'Bash(git push:*)'
check "lp-named: floor unioned into deny (sudo)" 'Bash(sudo:*)'
check "lp-named: floor unioned into deny (rm -rf)" 'Bash(rm -rf:*)'
check "lp-named: floor unioned into deny (mkfs.*)" 'Bash(mkfs.*:*)'
grep -qE -- "--prompt [^ ]*/autonomous\.md" "$TMUX_STUB_DIR/calls.log" \
  && echo "ok   - lp-named: autonomous prompt passed" \
  || { echo "FAIL - lp-named: autonomous prompt not passed"; fail=1; }
[[ "$(record "$rec" profile)" == "trusted" ]] \
  && echo "ok   - lp-named: record profile is trusted" \
  || { echo "FAIL - lp-named: record profile is $(record "$rec" profile)"; fail=1; }
"$specforge" session list >"$out" 2>&1
check "lp-named: session list shows the profile" "trusted"
diff -q "$root/.nogging/launch-profiles/trusted.json" \
        "$repo_root/.nogging/launch-profiles/trusted.json" >/dev/null \
  && echo "ok   - lp-named: source trusted profile left unmutated" \
  || { echo "FAIL - lp-named: source profile changed"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: every launch-floor rule is a valid permission rule and reaches the
# launched session verbatim (TASK-HY-007). Catches a future malformed floor
# entry (empty/nested parens, like the removed fork-bomb rule) before it ships.
# ===========================================================================
root="$work/floor"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/floor-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-fl1"
"$specforge" session launch --role lead --bead SPEC-fl1 --profile trusted >/dev/null 2>&1
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
eff="$(record "$root/.nogging/state/sessions/$name.json" effective_settings_path)"
floor_out=$(python3 - "$repo_root/scripts/nogg" "$eff" <<'PY'
import json, re, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_floor", sys.argv[1]).load_module()
valid = re.compile(r'^(Bash\([^()]*\S[^()]*\)|Bash|WebFetch)$')
bad = [e for e in m.FLOOR_DENY if not valid.match(e)]
if bad:
    print("INVALID:", bad); sys.exit(1)
deny = json.load(open(sys.argv[2]))["permissions"]["deny"]
missing = [e for e in m.FLOOR_DENY if e not in deny]
if missing:
    print("MISSING:", missing); sys.exit(1)
print("OK %d floor entries valid and present verbatim" % len(m.FLOOR_DENY))
PY
) && floor_rc=0 || floor_rc=$?
[[ "$floor_rc" -eq 0 ]] \
  && echo "ok   - floor: every FLOOR_DENY entry is a valid rule and reaches the effective settings verbatim ($floor_out)" \
  || { echo "FAIL - floor: $floor_out"; fail=1; }
unset SPECFORGE_ROOT

# Every deny entry in every shipped launch-profile is a syntactically valid rule
# (SPEC-3m8 / SPEC-js9: trusted.json shipped an invalid fork-bomb string that
# Claude Code rejected and that tripped a settings-warning dialog at launch).
prof_out=$(python3 - "$repo_root/.nogging/launch-profiles" <<'PY'
import json, re, sys, pathlib
valid = re.compile(r'^(Bash\([^()]*\S[^()]*\)|Bash|WebFetch)$')
bad = {}
for p in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    deny = json.load(open(p)).get("permissions", {}).get("deny", [])
    offenders = [e for e in deny if not valid.match(e)]
    if offenders:
        bad[p.name] = offenders
if bad:
    print("INVALID:", bad); sys.exit(1)
print("OK all shipped launch-profile deny entries valid")
PY
) && prof_rc=0 || prof_rc=$?
[[ "$prof_rc" -eq 0 ]] \
  && echo "ok   - profiles: every deny entry in every shipped launch-profile is a valid rule ($prof_out)" \
  || { echo "FAIL - profiles: $prof_out"; fail=1; }

# ===========================================================================
# Scenario: --full-access == --profile trusted --prompt autonomous
# ===========================================================================
root="$work/lp-full"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/lp-full-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-lp3"
"$specforge" session launch --role lead --bead SPEC-lp3 --full-access >"$out" 2>&1 \
  || { echo "FAIL - lp-full: launch errored"; cat "$out"; fail=1; }
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"
[[ "$(record "$rec" profile)" == "trusted" ]] \
  && echo "ok   - lp-full: selects the trusted profile" \
  || { echo "FAIL - lp-full: profile is $(record "$rec" profile)"; fail=1; }
grep -qE -- "--prompt [^ ]*/autonomous\.md" "$TMUX_STUB_DIR/calls.log" \
  && echo "ok   - lp-full: selects the autonomous prompt" \
  || { echo "FAIL - lp-full: autonomous prompt not passed"; fail=1; }
cp "$(record "$rec" effective_settings_path)" "$out"
check "lp-full: floored trusted settings written" '"defaultMode": "acceptEdits"'
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: a supplied path resolves and the floor survives a permissive file
# ===========================================================================
root="$work/lp-path"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/lp-path-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-lp4"
permissive="$work/permissive-profile.json"
cat >"$permissive" <<'JSON'
{ "permissions": { "defaultMode": "bypassPermissions", "allow": ["Bash(sudo:*)"], "deny": [] } }
JSON
"$specforge" session launch --role lead --bead SPEC-lp4 --profile "$permissive" >"$out" 2>&1 \
  || { echo "FAIL - lp-path: launch errored"; cat "$out"; fail=1; }
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"
[[ "$(record "$rec" profile)" == "permissive-profile.json" ]] \
  && echo "ok   - lp-path: record profile is the supplied basename" \
  || { echo "FAIL - lp-path: profile is $(record "$rec" profile)"; fail=1; }
cp "$(record "$rec" effective_settings_path)" "$out"
check "lp-path: floor forced into a permissive supplied profile (sudo)" 'Bash(sudo:*)'
check "lp-path: floor forced into a permissive supplied profile (rm -rf)" 'Bash(rm -rf:*)'
check "lp-path: floor forced into a permissive supplied profile (mkfs.*)" 'Bash(mkfs.*:*)'
[[ "$(cksum <"$permissive")" == "$(cksum <"$permissive")" ]]   # sanity
grep -qF '"deny": []' "$permissive" \
  && echo "ok   - lp-path: the supplied source file itself was not mutated" \
  || { echo "FAIL - lp-path: supplied profile file changed"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: an unknown profile fails before any session exists
# ===========================================================================
root="$work/lp-unknown"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/lp-unknown-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-lp5"
"$specforge" session launch --role lead --bead SPEC-lp5 --profile no-such-profile >"$out" 2>&1 \
  && { echo "FAIL - lp-unknown: launch should have failed"; fail=1; } \
  || echo "ok   - lp-unknown: launch refused for an unresolvable profile"
check "lp-unknown: message explains the resolution failure" "did not resolve"
[[ -z "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null)" ]] \
  && echo "ok   - lp-unknown: no session record or settings file was created" \
  || { echo "FAIL - lp-unknown: session state left behind"; ls -A "$root/.nogging/state/sessions"; fail=1; }
[[ ! -f "$TMUX_STUB_DIR/calls.log" ]] || ! grep -qF "new-session " "$TMUX_STUB_DIR/calls.log" \
  && echo "ok   - lp-unknown: no tmux session was created" \
  || { echo "FAIL - lp-unknown: tmux new-session was called"; cat "$TMUX_STUB_DIR/calls.log"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: cleanup removes the per-session effective-settings file
# ===========================================================================
root="$work/lp-cleanup"; make_root "$root" 0.2
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/lp-cleanup-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-lp6"
"$specforge" session launch --role lead --bead SPEC-lp6 --profile trusted >/dev/null 2>&1
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"
eff="$(record "$rec" effective_settings_path)"
[[ -f "$eff" ]] || { echo "FAIL - lp-cleanup: no effective-settings file to begin with"; fail=1; }
"$specforge" session stop "$name" >/dev/null 2>&1
"$specforge" session cleanup "$name" >"$out" 2>&1 \
  || { echo "FAIL - lp-cleanup: cleanup errored"; cat "$out"; fail=1; }
[[ ! -f "$eff" ]] \
  && echo "ok   - lp-cleanup: effective-settings file removed when the record retired" \
  || { echo "FAIL - lp-cleanup: effective-settings file survived cleanup"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: the per-session <name>.settings.json is not mistaken for a record
# (TASK-HY-005). It is valid JSON, so a bare *.json glob used to load it as a
# bogus session — a spurious `unknown` row in `list` and a fooled no-name
# `cleanup` server-kill guard.
# ===========================================================================
root="$work/set-file"; make_root "$root" 0.2
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/set-file-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-sf1"
"$specforge" session launch --role lead --bead SPEC-sf1 >/dev/null 2>&1
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
[[ -f "$root/.nogging/state/sessions/$name.settings.json" ]] \
  && echo "ok   - set-file: launch left a <name>.settings.json beside the record" \
  || { echo "FAIL - set-file: no settings file to test against"; fail=1; }

env -u TERM "$specforge" session list >"$out" 2>&1
check "set-file: list shows the real session" "$name"
check "set-file: list shows the real Bead" "SPEC-sf1"
refute "set-file: no spurious unknown-state row" "unknown"
[[ "$(grep -c "SPEC-sf1" "$out")" == "1" ]] \
  && echo "ok   - set-file: exactly one session row is listed" \
  || { echo "FAIL - set-file: unexpected row count"; cat "$out"; fail=1; }

# No real record left active, but a tmux session lingers on the dedicated server.
"$specforge" session stop "$name" >/dev/null 2>&1
touch "$TMUX_STUB_DIR/sess-lingering"
"$specforge" session cleanup >"$out" 2>&1 \
  || { echo "FAIL - set-file: cleanup errored"; cat "$out"; fail=1; }
check "set-file: the stopped record is retired" "retired $name"
check "set-file: no-name cleanup stops the tmux server once nothing real is active" \
  "SpecForge tmux server stopped"
[[ -z "$(ls "$TMUX_STUB_DIR"/sess-* 2>/dev/null)" ]] \
  && echo "ok   - set-file: the lingering tmux session was torn down" \
  || { echo "FAIL - set-file: tmux session survived the server stop"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: --agent codex maps the level onto Codex's sandbox/approval model
# ===========================================================================
# codex stub: PATH-injected, logs its argv, never starts a real session.
cat >"$work/bin/codex" <<'STUB'
#!/usr/bin/env bash
{ printf 'codex'; for a in "$@"; do printf ' <%s>' "$a"; done; printf '\n'; } \
  >>"${CODEX_ARGV_LOG:?CODEX_ARGV_LOG unset}"
STUB
chmod +x "$work/bin/codex"

root="$work/codex-full"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/codex-full-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-cdx"
"$specforge" session launch --role lead --bead SPEC-cdx --agent codex --full-access >"$out" 2>&1 \
  || { echo "FAIL - codex-full: launch errored"; cat "$out"; fail=1; }
check "codex-full: missing-floor warning names the execpolicy file" "specforge.rules"
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"
[[ "$(record "$rec" agent)" == "codex" ]] \
  && echo "ok   - codex-full: record shows agent codex" \
  || { echo "FAIL - codex-full: agent is $(record "$rec" agent)"; fail=1; }
[[ "$(record "$rec" effective_settings_path)" == "None" ]] \
  && echo "ok   - codex-full: no per-session effective-settings file for Codex" \
  || { echo "FAIL - codex-full: effective_settings_path is $(record "$rec" effective_settings_path)"; fail=1; }
[[ ! -f "$root/.nogging/state/sessions/$name.settings.json" ]] \
  && echo "ok   - codex-full: no <name>.settings.json written" \
  || { echo "FAIL - codex-full: a settings file was written for Codex"; fail=1; }
cp "$TMUX_STUB_DIR/calls.log" "$out"
check "codex-full: wrapper call carries --agent codex"          "--agent codex"
check "codex-full: trusted maps to workspace-write sandbox"     "--sandbox workspace-write"
check "codex-full: trusted maps to approval never"              "--approval never"
check "codex-full: trusted enables outbound network"            "--network on"
check "codex-full: openspec/ requested as a read-only root (TASK-TWB-004)" "--readonly-root"
grep -qE -- "--readonly-root [^ ]*/openspec" "$out" \
  && echo "ok   - codex-full: the read-only root is the session's openspec/ dir" \
  || { echo "FAIL - codex-full: --readonly-root path is not openspec/"; cat "$out"; fail=1; }
"$specforge" session list >"$out" 2>&1
check "codex-full: session list has an AGENT column"            "AGENT"
check "codex-full: session list shows codex for the session"    "codex"
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: the wrapper execs `codex` with the mapped flags, and never a
# rule-ignoring or sandbox-bypassing flag
# ===========================================================================
export CODEX_ARGV_LOG="$work/codex-argv.log"; : >"$CODEX_ARGV_LOG"
"$here/session-launch" --agent codex --sandbox read-only --approval on-request \
  --network on --prompt "$work/codex-full/.nogging/launch-prompts/autonomous.md" \
  --cwd "$work/codex-full" --bead SPEC-cdx >"$out" 2>&1 \
  || { echo "FAIL - codex-wrap: wrapper errored"; cat "$out"; fail=1; }
cp "$CODEX_ARGV_LOG" "$out"
check "codex-wrap: passes --cd"                         "<--cd>"
check "codex-wrap: passes the sandbox mode to --sandbox" "<--sandbox> <read-only>"
check "codex-wrap: maps approval to --ask-for-approval" "<--ask-for-approval> <on-request>"
check "codex-wrap: --network on enables network via -c override" "sandbox_workspace_write.network_access=true"
refute "codex-wrap: --network on does not also emit the =false override" "network_access=false"
refute "codex-wrap: never passes --ignore-rules"       "ignore-rules"
refute "codex-wrap: never bypasses approvals/sandbox"  "dangerously-bypass"

# ... and --network off emits the =false override (restricted path)
: >"$CODEX_ARGV_LOG"
"$here/session-launch" --agent codex --sandbox read-only --approval on-request \
  --network off --prompt "$work/codex-full/.nogging/launch-prompts/autonomous.md" \
  --cwd "$work/codex-full" --bead SPEC-cdx >"$out" 2>&1 \
  || { echo "FAIL - codex-wrap-off: wrapper errored"; cat "$out"; fail=1; }
cp "$CODEX_ARGV_LOG" "$out"
check  "codex-wrap-off: --network off disables network via -c override" "sandbox_workspace_write.network_access=false"
refute "codex-wrap-off: --network off does not emit the =true override" "network_access=true"

# ===========================================================================
# Scenario: --read-only forces the Codex sandbox to read-only at launch
# ===========================================================================
root="$work/codex-ro"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/codex-ro-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-cro"
"$specforge" session launch --role lead --bead SPEC-cro --agent codex --read-only >"$out" 2>&1 \
  || { echo "FAIL - codex-ro: launch errored"; cat "$out"; fail=1; }
cp "$TMUX_STUB_DIR/calls.log" "$out"
check "codex-ro: --read-only forces --sandbox read-only" "--sandbox read-only"
check "codex-ro: restricted level keeps outbound network off" "--network off"
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: a Claude settings file with --agent codex fails before any session
# ===========================================================================
root="$work/codex-reject"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/codex-reject-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-rej"
"$specforge" session launch --role lead --bead SPEC-rej --agent codex \
  --profile "$root/.nogging/launch-profiles/restricted.json" >"$out" 2>&1 \
  && { echo "FAIL - codex-reject: launch should have failed"; fail=1; } \
  || echo "ok   - codex-reject: a .json profile with --agent codex is refused"
check "codex-reject: message says it is a Claude settings file" "Claude settings file"
[[ -z "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null)" ]] \
  && echo "ok   - codex-reject: no session record was created" \
  || { echo "FAIL - codex-reject: session state left behind"; ls -A "$root/.nogging/state/sessions"; fail=1; }
[[ ! -f "$TMUX_STUB_DIR/calls.log" ]] || ! grep -qF "new-session " "$TMUX_STUB_DIR/calls.log" \
  && echo "ok   - codex-reject: no tmux session was created" \
  || { echo "FAIL - codex-reject: tmux new-session was called"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: --agent pi --full-access (trusted) maps onto the always-on guard
# extension (TASK-PIA-010)
# ===========================================================================
# pi stub: PATH-injected, logs its argv, never starts a real process.
cat >"$work/bin/pi" <<'STUB'
#!/usr/bin/env bash
{ printf 'pi'; for a in "$@"; do printf ' <%s>' "$a"; done; printf '\n'; } \
  >>"${PI_ARGV_LOG:?PI_ARGV_LOG unset}"
STUB
chmod +x "$work/bin/pi"

root="$work/pi-full"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/pi-full-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-pia"
"$specforge" session launch --role lead --bead SPEC-pia --agent pi --full-access >"$out" 2>&1 \
  || { echo "FAIL - pi-full: launch errored"; cat "$out"; fail=1; }
check "pi-full: missing-floor warning names the guard extension" ".pi/extensions/specforge-guard.ts"
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"
[[ "$(record "$rec" agent)" == "pi" ]] \
  && echo "ok   - pi-full: record shows agent pi" \
  || { echo "FAIL - pi-full: agent is $(record "$rec" agent)"; fail=1; }
[[ "$(record "$rec" effective_settings_path)" == "None" ]] \
  && echo "ok   - pi-full: no per-session effective-settings file for Pi" \
  || { echo "FAIL - pi-full: effective_settings_path is $(record "$rec" effective_settings_path)"; fail=1; }
[[ ! -f "$root/.nogging/state/sessions/$name.settings.json" ]] \
  && echo "ok   - pi-full: no <name>.settings.json written" \
  || { echo "FAIL - pi-full: a settings file was written for Pi"; fail=1; }
cp "$TMUX_STUB_DIR/calls.log" "$out"
check "pi-full: wrapper call carries --agent pi" "--agent pi"
"$specforge" session list >"$out" 2>&1
check "pi-full: session list has an AGENT column"         "AGENT"
# a bare "pi" substring would spuriously match "SPEC-pia" itself, so anchor on
# the padded AGENT cell (2+ spaces on both sides — see _agent_display()).
check "pi-full: session list shows pi in the AGENT column" "  pi  "
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: --agent pi with no --full-access stays on the restricted profile
# (the observable difference from the trusted scenario above is which prompt
# resolves and which profile label is recorded — the guard extension itself
# is never suppressed at either level, by design)
# ===========================================================================
root="$work/pi-restricted"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/pi-restricted-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-pir"
"$specforge" session launch --role lead --bead SPEC-pir --agent pi >"$out" 2>&1 \
  || { echo "FAIL - pi-restricted: launch errored"; cat "$out"; fail=1; }
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"
[[ "$(record "$rec" agent)" == "pi" ]] \
  && echo "ok   - pi-restricted: record shows agent pi" \
  || { echo "FAIL - pi-restricted: agent is $(record "$rec" agent)"; fail=1; }
[[ "$(record "$rec" profile)" == "restricted" ]] \
  && echo "ok   - pi-restricted: record profile is restricted (no --full-access)" \
  || { echo "FAIL - pi-restricted: record profile is $(record "$rec" profile)"; fail=1; }
cp "$TMUX_STUB_DIR/calls.log" "$out"
grep -qE -- "--prompt [^ ]*/no-autonomous-claim\.md" "$out" \
  && echo "ok   - pi-restricted: no-autonomous-claim prompt resolved (vs. autonomous for trusted)" \
  || { echo "FAIL - pi-restricted: default prompt not passed"; cat "$out"; fail=1; }
refute "pi-restricted: no guard-suppressing flag is ever emitted" "no-approve"
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: the wrapper execs `pi` with the mapped flags, and never a flag
# that would suppress or bypass the always-on guard extension
# ===========================================================================
export PI_ARGV_LOG="$work/pi-argv.log"; : >"$PI_ARGV_LOG"
"$here/session-launch" --agent pi --provider anthropic --model claude-x \
  --prompt "$work/pi-full/.nogging/launch-prompts/autonomous.md" \
  --cwd "$work/pi-full" --bead SPEC-pia >"$out" 2>&1 \
  || { echo "FAIL - pi-wrap: wrapper errored"; cat "$out"; fail=1; }
cp "$PI_ARGV_LOG" "$out"
check "pi-wrap: always passes --approve"                       "<--approve>"
check "pi-wrap: forwards --provider"                           "<--provider> <anthropic>"
check "pi-wrap: forwards --model"                              "<--model> <claude-x>"
check "pi-wrap: appends the prompt via --append-system-prompt" "<--append-system-prompt>"
refute "pi-wrap: never passes --no-approve"     "no-approve"
refute "pi-wrap: never passes --no-extensions"  "no-extensions"

# ===========================================================================
# Scenario: a Claude settings file with --agent pi fails before any session
# ===========================================================================
root="$work/pi-reject-json"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/pi-reject-json-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-prc"
"$specforge" session launch --role lead --bead SPEC-prc --agent pi \
  --profile "$root/.nogging/launch-profiles/restricted.json" >"$out" 2>&1 \
  && { echo "FAIL - pi-reject-json: launch should have failed"; fail=1; } \
  || echo "ok   - pi-reject-json: a .json profile with --agent pi is refused"
check "pi-reject-json: message says it is a Claude settings file" "Claude settings file"
[[ -z "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null)" ]] \
  && echo "ok   - pi-reject-json: no session record was created" \
  || { echo "FAIL - pi-reject-json: session state left behind"; ls -A "$root/.nogging/state/sessions"; fail=1; }
[[ ! -f "$TMUX_STUB_DIR/calls.log" ]] || ! grep -qF "new-session " "$TMUX_STUB_DIR/calls.log" \
  && echo "ok   - pi-reject-json: no tmux session was created" \
  || { echo "FAIL - pi-reject-json: tmux new-session was called"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: a Codex .codex.toml profile with --agent pi is also refused (the
# endswith(".codex.toml") check in resolve_pi_profile() — Path.suffix alone
# would not catch this, since it only returns the LAST suffix, ".toml")
# ===========================================================================
root="$work/pi-reject-codex-toml"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/pi-reject-codex-toml-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-prt"
"$specforge" session launch --role lead --bead SPEC-prt --agent pi \
  --profile "$root/.nogging/launch-profiles/restricted.codex.toml" >"$out" 2>&1 \
  && { echo "FAIL - pi-reject-codex-toml: launch should have failed"; fail=1; } \
  || echo "ok   - pi-reject-codex-toml: a .codex.toml profile with --agent pi is refused"
check "pi-reject-codex-toml: message says it is a Codex launch spec" "Codex launch spec"
[[ -z "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null)" ]] \
  && echo "ok   - pi-reject-codex-toml: no session record was created" \
  || { echo "FAIL - pi-reject-codex-toml: session state left behind"; ls -A "$root/.nogging/state/sessions"; fail=1; }
[[ ! -f "$TMUX_STUB_DIR/calls.log" ]] || ! grep -qF "new-session " "$TMUX_STUB_DIR/calls.log" \
  && echo "ok   - pi-reject-codex-toml: no tmux session was created" \
  || { echo "FAIL - pi-reject-codex-toml: tmux new-session was called"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: the default launch still execs `claude` — no --agent argument
# ===========================================================================
root="$work/codex-default"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/codex-default-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-dfl"
"$specforge" session launch --role lead --bead SPEC-dfl >"$out" 2>&1 \
  || { echo "FAIL - codex-default: launch errored"; cat "$out"; fail=1; }
name="$(ls "$root/.nogging/state/sessions" | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
[[ "$(record "$root/.nogging/state/sessions/$name.json" agent)" == "claude" ]] \
  && echo "ok   - codex-default: record agent is claude" \
  || { echo "FAIL - codex-default: agent is $(record "$root/.nogging/state/sessions/$name.json" agent)"; fail=1; }
cp "$TMUX_STUB_DIR/calls.log" "$out"
check   "codex-default: still a claude wrapper call with --settings" "--settings "
refute  "codex-default: no --agent argument on the default path"     "--agent"
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: redact() scrubs a secret-named value in a `-c key=value` override
# ===========================================================================
red_out=$(python3 - "$repo_root/scripts/nogg" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_redact", sys.argv[1]).load_module()
print(m.redact("codex -c 'model_providers.x.auth_token=\"sk-DO-NOT-LEAK-abc\"' --cd ."))
print(m.redact("codex -c sandbox_workspace_write.network_access=false"))
PY
)
[[ "$red_out" == *'***REDACTED***'* && "$red_out" != *'sk-DO-NOT-LEAK-abc'* ]] \
  && echo "ok   - redact-c: a secret-named -c override value is scrubbed in the record" \
  || { echo "FAIL - redact-c: secret survived redact() ($red_out)"; fail=1; }
[[ "$red_out" == *'network_access=false'* ]] \
  && echo "ok   - redact-c: a non-secret -c override is left intact" \
  || { echo "FAIL - redact-c: over-redacted a benign override ($red_out)"; fail=1; }

# ===========================================================================
# Scenario: --role orchestrator launches Bead-less, FULL-ACCESS, floor lifted
# (TASK-ORC-003 / TASK-ORC-004)
# ===========================================================================
root="$work/orc"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/orc-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN=""
"$specforge" session launch --role orchestrator --profile orchestrator >"$out" 2>&1 \
  || { echo "FAIL - orc: launch errored"; cat "$out"; fail=1; }
check "orc: launch reports the singleton name" "launched nogg-orchestrator-orc"
orcrec="$root/.nogging/state/sessions/nogg-orchestrator-orc.json"
[[ -f "$orcrec" ]] \
  && echo "ok   - orc: record written under the fixed name" \
  || { echo "FAIL - orc: no record at the fixed name"; fail=1; }
[[ "$(record "$orcrec" bead_id)" == "None" ]] \
  && echo "ok   - orc: record carries a null Bead id" \
  || { echo "FAIL - orc: bead_id is $(record "$orcrec" bead_id)"; fail=1; }
[[ "$(record "$orcrec" role)" == "orchestrator" ]] \
  && echo "ok   - orc: record role is orchestrator" \
  || { echo "FAIL - orc: role is $(record "$orcrec" role)"; fail=1; }
[[ "$(record "$orcrec" floor_lifted)" == "True" ]] \
  && echo "ok   - orc: record marks floor_lifted true" \
  || { echo "FAIL - orc: floor_lifted is $(record "$orcrec" floor_lifted)"; fail=1; }
[[ "$(record "$orcrec" openspec_readonly)" == "False" ]] \
  && echo "ok   - orc: openspec/ read-only root not applied" \
  || { echo "FAIL - orc: openspec_readonly is $(record "$orcrec" openspec_readonly)"; fail=1; }
cp "$(record "$orcrec" effective_settings_path)" "$out"
check "orc: effective settings keep bypassPermissions" '"defaultMode": "bypassPermissions"'
check "orc: effective settings keep the accepted-disclaimer key" '"skipDangerousModePermissionPrompt": true'
refute "orc: no floor deny in the effective settings (sudo)"  'Bash(sudo:*)'
refute "orc: no floor deny in the effective settings (rm -rf)" 'Bash(rm -rf:*)'
refute "orc: no openspec/ deny in the effective settings" 'Edit(openspec/**)'
refute "orc: the SpecForge-only keys never reach Claude" 'specforge_floor'
env -u TERM "$specforge" session list >"$out" 2>&1
check "orc: session list shows the orchestrator row" "nogg-orchestrator-orc"
check "orc: session list marks it FULL-ACCESS" "FULL-ACCESS"
"$specforge" session launch --role orchestrator --profile orchestrator >"$out" 2>&1 \
  && { echo "FAIL - orc: a second orchestrator launch should be refused"; fail=1; } \
  || echo "ok   - orc: a second live orchestrator launch is refused"
check "orc: the refusal points at orchestrator run" "orchestrator run"
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: --bead is still required for every non-orchestrator role
# ===========================================================================
root="$work/orc-bead"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/orc-bead-tmux"; mkdir -p "$TMUX_STUB_DIR"
"$specforge" session launch --role lead >"$out" 2>&1 \
  && { echo "FAIL - orc-bead: lead without --bead should fail"; fail=1; } \
  || echo "ok   - orc-bead: lead without --bead is refused"
check "orc-bead: the message names the orchestrator exception" "except 'orchestrator'"
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: the orchestrator profile's floor keys are ignored for other roles —
# a lead session on --profile orchestrator still runs floored and fenced
# (TASK-ORC-004)
# ===========================================================================
root="$work/orc-lead"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/orc-lead-tmux"; mkdir -p "$TMUX_STUB_DIR"
export BD_KNOWN="SPEC-ol1"
"$specforge" session launch --role lead --bead SPEC-ol1 --profile orchestrator >"$out" 2>&1 \
  || { echo "FAIL - orc-lead: launch errored"; cat "$out"; fail=1; }
name="$(ls "$root/.nogging/state/sessions" | grep '^sf-lead' | grep '\.json$' | grep -v '\.settings\.json$' | sed 's/\.json$//')"
rec="$root/.nogging/state/sessions/$name.json"
[[ "$(record "$rec" floor_lifted)" == "False" ]] \
  && echo "ok   - orc-lead: floor NOT lifted for a lead on the orchestrator profile" \
  || { echo "FAIL - orc-lead: floor_lifted is $(record "$rec" floor_lifted)"; fail=1; }
cp "$(record "$rec" effective_settings_path)" "$out"
check "orc-lead: the floor is still unioned in (sudo)"  'Bash(sudo:*)'
check "orc-lead: the floor is still unioned in (rm -rf)" 'Bash(rm -rf:*)'
check "orc-lead: openspec/ is still fenced" 'Edit(openspec/**)'
[[ "$(record "$rec" openspec_readonly)" == "True" ]] \
  && echo "ok   - orc-lead: openspec/ read-only root still applied" \
  || { echo "FAIL - orc-lead: openspec_readonly is $(record "$rec" openspec_readonly)"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: --role orchestrator is refused for a non-Claude agent (Claude-only)
# ===========================================================================
root="$work/orc-codex"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/orc-codex-tmux"; mkdir -p "$TMUX_STUB_DIR"
"$specforge" session launch --role orchestrator --agent codex --profile orchestrator >"$out" 2>&1 \
  && { echo "FAIL - orc-codex: should be refused"; fail=1; } \
  || echo "ok   - orc-codex: --role orchestrator --agent codex is refused"
unset SPECFORGE_ROOT

if [[ $fail -ne 0 ]]; then echo "session checks failed" >&2; exit 1; fi
echo "all session checks passed"
