#!/usr/bin/env bash
# Regression checks for `scripts/nogg orchestrator ...` (TASK-ORC-012).
#
# tmux, claude, systemctl and loginctl are all STUBBED (PATH-injected, the same
# technique as scripts/session.test.sh): no real service, tmux server or Claude
# process is ever started. The tmux stub is stateful over $TMUX_STUB_DIR so the
# supervisor's "block until the session exits" poll is observable — the test
# removes the marker file to stand in for the session ending.
#
# Covered:
#   - the orchestrator lock: acquire, refuse a live second holder, --force
#     reclaim, and same-host dead-pid reclaim without --force;
#   - `run` cold start: acquires the lock, creates the singleton session, blocks
#     on the poll, then releases the lock and exits non-zero when it ends;
#   - `run` adopt path: a live session is re-adopted, no second Claude starts;
#   - `status` is read-only and reports the unit / linger / lock / session;
#   - `stop` is idempotent.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
specforge="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

fail=0
check()  { if grep -qF -- "$2" "$out"; then echo "ok   - $1"; else echo "FAIL - $1 (missing: $2)"; cat "$out"; fail=1; fi; }
refute() { if grep -qF -- "$2" "$out"; then echo "FAIL - $1 (present: $2)"; cat "$out"; fail=1; else echo "ok   - $1"; fi; }

# --- stubs ---------------------------------------------------------------
mkdir -p "$work/bin"

cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "-L" ]] && shift 2
cmd="${1:-}"; shift || true
d="${TMUX_STUB_DIR:?}"; mkdir -p "$d"
printf '%s %s\n' "$cmd" "$*" >>"$d/calls.log"
arg_after(){ local f="$1"; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$f" ]] && { printf '%s' "$2"; return; }; shift; done; }
case "$cmd" in
  new-session)  touch "$d/sess-$(arg_after -s "$@")" ;;
  has-session)  [[ -f "$d/sess-$(arg_after -t "$@")" ]] ;;
  list-sessions) for f in "$d"/sess-*; do [[ -e "$f" ]] || continue; echo "${f##*/sess-}"; done ;;
  kill-session|send-keys)
    n="$(arg_after -t "$@")"
    [[ "$cmd" == kill-session ]] && rm -f "$d/sess-$n" ;;
  pipe-pane|kill-server|attach) : ;;
  *) : ;;
esac
STUB

cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "show" ]] && { printf '[{"id":"%s","title":"x"}]\n' "${2:-}"; exit 0; }
exit 1
STUB

cat >"$work/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'claude %s\n' "$*" >>"${CLAUDE_LOG:?}"
STUB

cat >"$work/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
# is-enabled / is-active <unit>  -> read from $SYSTEMCTL_STATE_DIR
sub="${2:-}"; unit="${3:-}"
case "$sub" in
  is-enabled) cat "${SYSTEMCTL_STATE_DIR}/enabled" 2>/dev/null || { echo "not-found"; exit 1; } ;;
  is-active)  cat "${SYSTEMCTL_STATE_DIR}/active"  2>/dev/null || { echo "inactive"; exit 3; } ;;
  stop|disable) echo "disabled" >"${SYSTEMCTL_STATE_DIR}/enabled"; echo "inactive" >"${SYSTEMCTL_STATE_DIR}/active" ;;
  restart) echo "active" >"${SYSTEMCTL_STATE_DIR}/active" ;;
  *) : ;;
esac
STUB

cat >"$work/bin/loginctl" <<'STUB'
#!/usr/bin/env bash
echo "Linger=${LINGER_STATE:-no}"
STUB

chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

# make_root <dir> — a minimal SpecForge checkout with a low poll interval
make_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state" "$r/scripts"
  cp -r "$repo_root/.nogging/launch-profiles" "$r/.nogging/"
  cp -r "$repo_root/.nogging/launch-prompts" "$r/.nogging/"
  ln -sf "$repo_root/scripts/session-launch" "$r/scripts/session-launch"
  ln -sf "$repo_root/scripts/session-log-writer" "$r/scripts/session-log-writer"
  python3 - "$repo_root/.nogging/config.json" "$r/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["orchestrator_poll_seconds"] = 0.2
cfg["orchestrator_lock_ttl_seconds"] = 3600
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
}
record() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get(sys.argv[2]))" "$1" "$2"; }

# ===========================================================================
# The orchestrator lock primitive
# ===========================================================================
root="$work/lock"; make_root "$root"
lock_out=$(SPECFORGE_ROOT="$root" python3 - "$repo_root/scripts/nogg" <<'PY'
import json, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_orc", sys.argv[1]).load_module()
p = m.acquire_orchestrator_lock()
assert p.exists(), "lock not written"
try:
    m.acquire_orchestrator_lock(); print("FAIL second acquire succeeded")
except m.LockBusyError: print("ok refused a live second holder")
m.acquire_orchestrator_lock(force=True); print("ok --force reclaims")
d = json.load(open(p)); d["pid"] = 999999; json.dump(d, open(p, "w"))
m.acquire_orchestrator_lock(); print("ok same-host dead-pid reclaim without --force")
m.release_orchestrator_lock(); print("ok release removes the lock" if not p.exists() else "FAIL lock survived release")
PY
)
echo "$lock_out" >"$out"
check "lock: refuses a live second holder" "ok refused a live second holder"
check "lock: --force reclaims"              "ok --force reclaims"
check "lock: dead-pid reclaim needs no --force" "ok same-host dead-pid reclaim without --force"
check "lock: release removes the file"      "ok release removes the lock"
refute "lock: no FAIL lines"                "FAIL"

# ===========================================================================
# run: cold start acquires the lock, creates the session, then releases on exit
# ===========================================================================
root="$work/run"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/run-tmux"; mkdir -p "$TMUX_STUB_DIR"
export CLAUDE_LOG="$work/run-claude.log"; : >"$CLAUDE_LOG"
name="sf-orchestrator-run"

( set +e; "$specforge" orchestrator run >"$work/run.out" 2>&1; echo "$?" >"$work/run.rc" ) &
for _ in $(seq 1 80); do [[ -f "$TMUX_STUB_DIR/sess-$name" ]] && break; sleep 0.1; done
[[ -f "$TMUX_STUB_DIR/sess-$name" ]] \
  && echo "ok   - run: created the singleton tmux session" \
  || { echo "FAIL - run: no session created"; fail=1; }
[[ -f "$root/.nogging/locks/orchestrator.lock" ]] \
  && echo "ok   - run: holds the orchestrator lock while supervising" \
  || { echo "FAIL - run: lock not held"; fail=1; }
[[ "$(record "$root/.nogging/state/sessions/$name.json" floor_lifted)" == "True" ]] \
  && echo "ok   - run: the session record is FULL-ACCESS (floor_lifted)" \
  || { echo "FAIL - run: floor_lifted not set"; fail=1; }
rm -f "$TMUX_STUB_DIR/sess-$name"     # the session ends
for _ in $(seq 1 80); do [[ -f "$work/run.rc" ]] && break; sleep 0.1; done
[[ "$(cat "$work/run.rc" 2>/dev/null)" == "1" ]] \
  && echo "ok   - run: exits non-zero when the session ends (so the unit restarts it)" \
  || { echo "FAIL - run: exit code was $(cat "$work/run.rc" 2>/dev/null)"; fail=1; }
[[ ! -f "$root/.nogging/locks/orchestrator.lock" ]] \
  && echo "ok   - run: releases the lock on exit" \
  || { echo "FAIL - run: lock not released"; fail=1; }
[[ "$(record "$root/.nogging/state/sessions/$name.json" state)" == "stopped" ]] \
  && echo "ok   - run: marks the record terminal when the session ends" \
  || { echo "FAIL - run: record state is $(record "$root/.nogging/state/sessions/$name.json" state)"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# run: adopts a live session instead of starting a second Claude
# ===========================================================================
root="$work/adopt"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/adopt-tmux"; mkdir -p "$TMUX_STUB_DIR"
export CLAUDE_LOG="$work/adopt-claude.log"; : >"$CLAUDE_LOG"
name="sf-orchestrator-adopt"
mkdir -p "$root/.nogging/state/sessions"
touch "$TMUX_STUB_DIR/sess-$name"     # a live orchestrator tmux session already exists
printf '{"name":"%s","role":"orchestrator","bead_id":null,"state":"running","floor_lifted":true,"log_path":"%s"}\n' \
  "$name" "$root/.nogging/state/sessions/$name.log" >"$root/.nogging/state/sessions/$name.json"

( set +e; "$specforge" orchestrator run >"$work/adopt.out" 2>&1; echo "$?" >"$work/adopt.rc" ) &
# wait until the supervisor is past its startup (lock taken), then end the session
for _ in $(seq 1 80); do [[ -f "$root/.nogging/locks/orchestrator.lock" ]] && break; sleep 0.1; done
sleep 0.5
rm -f "$TMUX_STUB_DIR/sess-$name"
for _ in $(seq 1 80); do [[ -f "$work/adopt.rc" ]] && break; sleep 0.1; done
cp "$work/adopt.out" "$out"
check "adopt: run adopts the live session" "adopting the live session $name"
grep -qF "new-session" "$TMUX_STUB_DIR/calls.log" \
  && { echo "FAIL - adopt: a second tmux session was created"; fail=1; } \
  || echo "ok   - adopt: no second tmux session is created"
[[ ! -s "$CLAUDE_LOG" ]] \
  && echo "ok   - adopt: no second Claude process is started" \
  || { echo "FAIL - adopt: claude was invoked"; cat "$CLAUDE_LOG"; fail=1; }
[[ ! -f "$root/.nogging/locks/orchestrator.lock" ]] \
  && echo "ok   - adopt: releases the lock on exit" \
  || { echo "FAIL - adopt: lock not released"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# status is read-only; stop is idempotent
# ===========================================================================
root="$work/status"; make_root "$root"
export SPECFORGE_ROOT="$root"
export TMUX_STUB_DIR="$work/status-tmux"; mkdir -p "$TMUX_STUB_DIR"
export SYSTEMCTL_STATE_DIR="$work/status-sysd"; mkdir -p "$SYSTEMCTL_STATE_DIR"
echo "enabled" >"$SYSTEMCTL_STATE_DIR/enabled"
echo "active"  >"$SYSTEMCTL_STATE_DIR/active"
export LINGER_STATE="no"

"$specforge" orchestrator status >"$out" 2>&1
check "status: names the per-repo unit"      "specforge-orchestrator-status.service"
check "status: reports the enabled state"    "enabled"
check "status: reports linger off"           "linger:  off"
check "status: reports no live session"      "no live orchestrator session"
[[ -z "$(ls -A "$root/.nogging/state/sessions" 2>/dev/null)" ]] \
  && echo "ok   - status: wrote no session state (read-only)" \
  || { echo "FAIL - status: mutated session state"; fail=1; }

"$specforge" orchestrator stop >"$out" 2>&1 \
  || { echo "FAIL - stop: errored"; cat "$out"; fail=1; }
check "stop: reports stopped and disabled" "stopped and disabled"
"$specforge" orchestrator stop >"$out" 2>&1 \
  && echo "ok   - stop: a second stop is a no-op success" \
  || { echo "FAIL - stop: second stop errored"; cat "$out"; fail=1; }
[[ "$(cat "$SYSTEMCTL_STATE_DIR/enabled")" == "disabled" ]] \
  && echo "ok   - stop: the unit stays disabled" \
  || { echo "FAIL - stop: unit not disabled"; fail=1; }
unset SPECFORGE_ROOT

if [[ $fail -ne 0 ]]; then echo "orchestrator checks failed" >&2; exit 1; fi
echo "all orchestrator checks passed"
