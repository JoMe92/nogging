#!/usr/bin/env bash
# Regression suite for orchestrator lock staleness and classifier (TASK-HHB-002, Decision 3).
# Follows Decision 1 test discipline:
#   - no Dolt and stubbed bd;
#   - no PID-range assumptions (live PIDs spawned and tracked, dead PIDs spawned and reaped);
#   - foreign PID-namespace tested via opaque strings;
#   - fenced caller tested via NOGG_OPENSPEC_FENCED=1 without unshare;
#   - clean environment unsetting inherited NOGG_*, HERDR_*, TMUX.
set -euo pipefail

# Clean inherited environment per Decision 1
for v in $(compgen -v | grep -E '^(NOGG_|HERDR_|TMUX)'); do
  unset "$v"
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
nogg="$repo_root/scripts/nogg"

work=$(mktemp -d /tmp/nogg.XXXXXX)
out=$(mktemp)
LIVE_PIDS=()

cleanup() {
  for pid in "${LIVE_PIDS[@]}"; do
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -f "$out"
  rm -rf "$work"
}
trap cleanup EXIT

fail=0
check()  { if grep -qF -- "$2" "$out"; then echo "ok   - $1"; else echo "FAIL - $1 (missing: $2)"; cat "$out"; fail=1; fi; }
refute() { if grep -qF -- "$2" "$out"; then echo "FAIL - $1 (present: $2)"; cat "$out"; fail=1; else echo "ok   - $1"; fi; }

# --- Stub bd -------------------------------------------------------------
mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  list) echo "[]" ;;
  show) echo '[{"id":"SPEC-000","title":"x","status":"closed"}]' ;;
  *) echo "[]" ;;
esac
STUB
chmod +x "$work/bin/bd"
export PATH="$work/bin:$PATH"

# Helpers for reliable PIDs per Decision 1
get_dead_pid() {
  python3 -c '
import subprocess, time
p = subprocess.Popen(["true"])
p.wait()
print(p.pid)
'
}

spawn_live_pid() {
  python3 -c 'import time; time.sleep(300)' >/dev/null 2>&1 &
  LAST_PID=$!
  LIVE_PIDS+=("$LAST_PID")
}

spawn_live_orchestrator_run() {
  local fake_dir="$1"
  mkdir -p "$fake_dir"
  cat >"$fake_dir/nogg" <<'PY'
#!/usr/bin/env python3
import time
time.sleep(300)
PY
  chmod +x "$fake_dir/nogg"
  python3 "$fake_dir/nogg" orchestrator run >/dev/null 2>&1 &
  LAST_PID=$!
  LIVE_PIDS+=("$LAST_PID")
}

make_fixture() {
  local dir="$1"
  mkdir -p "$dir/.nogging/locks" "$dir/.nogging/state" "$dir/scripts"
  ln -sf "$repo_root/scripts/nogg" "$dir/scripts/nogg"
  ln -sf "$repo_root/scripts/session-launch" "$dir/scripts/session-launch"
  ln -sf "$repo_root/scripts/session-log-writer" "$dir/scripts/session-log-writer"
  ln -sf "$repo_root/scripts/openspec-sandbox" "$dir/scripts/openspec-sandbox"
  python3 - "$repo_root/.nogging/config.json" "$dir/.nogging/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg["orchestrator_lock_ttl_seconds"] = 3600
cfg["beads_command"] = "bd"
json.dump(cfg, open(sys.argv[2], "w"), indent=2)
PY
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name 'Test Runner'
  git -C "$dir" add -A && git -C "$dir" commit -q -m 'chore: initial [SPEC-000]'
}

# ===========================================================================
# 1. Lock acquisition records pid_start and pid_ns
# ===========================================================================
fx1="$work/fx1"; make_fixture "$fx1"
NOGGING_ROOT="$fx1" python3 - "$nogg" >"$out" 2>&1 <<'PY'
import json, os, socket, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg_test", sys.argv[1]).load_module()

p = m.acquire_orchestrator_lock()
assert p.exists(), "lock not created"
data = json.loads(p.read_text())
assert data["pid"] == os.getpid(), f"unexpected pid: {data}"
assert data["host"] == socket.gethostname(), f"unexpected host: {data}"
assert "created_at" in data, f"missing created_at: {data}"
assert "pid_start" in data and data["pid_start"] == m.process_start(os.getpid()), f"missing or incorrect pid_start: {data}"
assert "pid_ns" in data and data["pid_ns"] == m.pid_namespace("self"), f"missing or incorrect pid_ns: {data}"
m.release_orchestrator_lock()
print("ok lock records pid_start and pid_ns")
PY
check "acquire_orchestrator_lock records pid_start and pid_ns" "ok lock records pid_start and pid_ns"

# ===========================================================================
# 2. Live verified holder: never stale at any age; recover & doctor report held
# ===========================================================================
fx2="$work/fx2"; make_fixture "$fx2"
spawn_live_pid; live_pid=$LAST_PID
# Write a lock for live_pid that is 2 days old (well past 3600s TTL)
python3 - "$fx2/.nogging/locks/orchestrator.lock" "$live_pid" <<'PY'
import json, socket, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg", "scripts/nogg").load_module()
path = sys.argv[1]
pid = int(sys.argv[2])
data = {
    "pid": pid,
    "host": socket.gethostname(),
    "created_at": "2026-10-10T10:00:00+00:00",
    "pid_start": m.process_start(pid),
    "pid_ns": m.pid_namespace(pid),
}
open(path, "w").write(json.dumps(data) + "\n")
PY

# Verify acquire_orchestrator_lock refuses second holder
NOGGING_ROOT="$fx2" python3 - "$nogg" <<'PY' >"$out" 2>&1
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg", sys.argv[1]).load_module()
try:
    m.acquire_orchestrator_lock()
    print("FAIL: acquire succeeded on live lock")
except m.LockBusyError:
    print("ok lock refused for live verified holder")
PY
check "refuse acquire on live verified holder" "ok lock refused for live verified holder"

# Verify recover reports held, not stale, and exits 0
( cd "$fx2" && NOGGING_ROOT="$fx2" "$nogg" recover ) >"$out" 2>&1 || { echo "FAIL - recover exited non-zero"; cat "$out"; fail=1; }
check "recover reports held (verified)" "orchestrator.lock: held (verified)"
refute "recover has no attention item" "stale orchestrator.lock"

# Verify doctor reports no attention needed
( cd "$fx2" && NOGGING_ROOT="$fx2" "$nogg" doctor ) >"$out" 2>&1 || true
check "doctor reports 0 attention items" "recover: 0 item(s) need attention"

# Verify status reports held
( cd "$fx2" && NOGGING_ROOT="$fx2" "$nogg" orchestrator status ) >"$out" 2>&1
check "status reports held" "lock:    held by"

# ===========================================================================
# 3. Dead holder (reaped child PID): stale, recover flags attention, reclaimed without --force
# ===========================================================================
fx3="$work/fx3"; make_fixture "$fx3"
dead_pid=$(get_dead_pid)
python3 - "$fx3/.nogging/locks/orchestrator.lock" "$dead_pid" <<'PY'
import json, socket, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg", "scripts/nogg").load_module()
open(sys.argv[1], "w").write(json.dumps({
    "pid": int(sys.argv[2]),
    "host": socket.gethostname(),
    "created_at": "2026-10-16T00:00:00+00:00",
    "pid_start": "12345",
    "pid_ns": m.pid_namespace("self")
}) + "\n")
PY

( cd "$fx3" && NOGGING_ROOT="$fx3" "$nogg" recover ) >"$out" 2>&1 && { echo "FAIL - recover should exit non-zero for dead holder"; cat "$out"; fail=1; } || true
check "recover reports dead holder as STALE" "orchestrator.lock: STALE"
check "recover flags attention for dead holder" "stale orchestrator.lock"

# Reclaim without --force
NOGGING_ROOT="$fx3" python3 - "$nogg" <<'PY' >"$out" 2>&1
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg", sys.argv[1]).load_module()
m.acquire_orchestrator_lock()
print("ok dead holder reclaimed without --force")
PY
check "reclaim dead holder without --force" "ok dead holder reclaimed without --force"

# ===========================================================================
# 4. Live PID with start time mismatch: stale, reclaimed without --force
# ===========================================================================
fx4="$work/fx4"; make_fixture "$fx4"
spawn_live_pid; live_pid2=$LAST_PID
python3 - "$fx4/.nogging/locks/orchestrator.lock" "$live_pid2" <<'PY'
import json, socket, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg", "scripts/nogg").load_module()
pid = int(sys.argv[2])
data = {
    "pid": pid,
    "host": socket.gethostname(),
    "created_at": "2026-10-16T00:00:00+00:00",
    "pid_start": "mismatched_birth_time_99999",
    "pid_ns": m.pid_namespace(pid)
}
open(sys.argv[1], "w").write(json.dumps(data) + "\n")
PY

( cd "$fx4" && NOGGING_ROOT="$fx4" "$nogg" recover ) >"$out" 2>&1 && { echo "FAIL - recover should exit non-zero for start time mismatch"; cat "$out"; fail=1; } || true
check "recover reports start time mismatch as STALE" "orchestrator.lock: STALE"

# Reclaim without --force
NOGGING_ROOT="$fx4" python3 - "$nogg" <<'PY' >"$out" 2>&1
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg", sys.argv[1]).load_module()
m.acquire_orchestrator_lock()
print("ok start time mismatch reclaimed without --force")
PY
check "reclaim mismatched start time without --force" "ok start time mismatch reclaimed without --force"

# ===========================================================================
# 5. Legacy lock (no pid_start):
#    - live `nogg ... orchestrator run` holder: held, verified (never stale)
#    - live PID running another command: dead (PID reused), stale
# ===========================================================================
fx5="$work/fx5"; make_fixture "$fx5"
spawn_live_orchestrator_run "$work/fake_orc_bin"; orc_pid=$LAST_PID

# 5a. Live orchestrator run holder in legacy lock (old age > 2 days)
python3 - "$fx5/.nogging/locks/orchestrator.lock" "$orc_pid" <<'PY'
import json, socket, sys
data = {
    "pid": int(sys.argv[2]),
    "host": socket.gethostname(),
    "created_at": "2026-10-10T10:00:00+00:00"
}
open(sys.argv[1], "w").write(json.dumps(data) + "\n")
PY

( cd "$fx5" && NOGGING_ROOT="$fx5" "$nogg" recover ) >"$out" 2>&1 || { echo "FAIL - recover exited non-zero for legacy orchestrator"; cat "$out"; fail=1; }
check "legacy orchestrator run holder is held" "orchestrator.lock: held (verified)"
refute "legacy orchestrator run has no attention item" "stale orchestrator.lock"

# 5b. Live PID running another command (e.g. sleep) in legacy lock
spawn_live_pid; other_pid=$LAST_PID
python3 - "$fx5/.nogging/locks/orchestrator.lock" "$other_pid" <<'PY'
import json, socket, sys
data = {
    "pid": int(sys.argv[2]),
    "host": socket.gethostname(),
    "created_at": "2026-10-16T00:00:00+00:00"
}
open(sys.argv[1], "w").write(json.dumps(data) + "\n")
PY

( cd "$fx5" && NOGGING_ROOT="$fx5" "$nogg" recover ) >"$out" 2>&1 && { echo "FAIL - recover should exit non-zero for reused PID"; cat "$out"; fail=1; } || true
check "legacy lock with other command reports STALE" "orchestrator.lock: STALE"
check "legacy lock with other command reports PID reused" "PID reused: another command"

# Reclaim without --force
NOGGING_ROOT="$fx5" python3 - "$nogg" <<'PY' >"$out" 2>&1
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg", sys.argv[1]).load_module()
m.acquire_orchestrator_lock()
print("ok legacy reused pid reclaimed without --force")
PY
check "reclaim legacy reused pid without --force" "ok legacy reused pid reclaimed without --force"

# ===========================================================================
# 6. Fenced caller (NOGG_OPENSPEC_FENCED=1): reports held (unverifiable), not stale
# ===========================================================================
fx6="$work/fx6"; make_fixture "$fx6"
# Lock pointing to host PID (e.g. dead or invisible in sandbox)
python3 - "$fx6/.nogging/locks/orchestrator.lock" <<'PY'
import json, socket, sys
data = {
    "pid": 926,
    "host": socket.gethostname(),
    "created_at": "2026-10-10T10:00:00+00:00"
}
open(sys.argv[1], "w").write(json.dumps(data) + "\n")
PY

( cd "$fx6" && NOGGING_ROOT="$fx6" NOGG_OPENSPEC_FENCED=1 "$nogg" recover ) >"$out" 2>&1 || { echo "FAIL - fenced recover exited non-zero"; cat "$out"; fail=1; }
check "fenced caller reports held (unverifiable)" "orchestrator.lock: held (unverifiable)"
check "fenced caller notes fenced caller" "unverifiable (fenced caller)"
refute "fenced caller has no attention item" "stale orchestrator.lock"

# ===========================================================================
# 7. Foreign PID namespace: reports held (unverifiable), not stale
# ===========================================================================
fx7="$work/fx7"; make_fixture "$fx7"
python3 - "$fx7/.nogging/locks/orchestrator.lock" <<'PY'
import json, socket, sys
data = {
    "pid": 926,
    "host": socket.gethostname(),
    "created_at": "2026-10-10T10:00:00+00:00",
    "pid_start": "12345",
    "pid_ns": "pid:[9999999999_foreign_ns]"
}
open(sys.argv[1], "w").write(json.dumps(data) + "\n")
PY

( cd "$fx7" && NOGGING_ROOT="$fx7" "$nogg" recover ) >"$out" 2>&1 || { echo "FAIL - foreign ns recover exited non-zero"; cat "$out"; fail=1; }
check "foreign ns reports held (unverifiable)" "orchestrator.lock: held (unverifiable)"
refute "foreign ns has no attention item" "stale orchestrator.lock"

# ===========================================================================
# 8. Another host: TTL decides staleness only here
# ===========================================================================
fx8="$work/fx8"; make_fixture "$fx8"

# 8a. Another host fresh (created 10s ago, TTL 3600s) -> held (unverifiable), not stale
python3 - "$fx8/.nogging/locks/orchestrator.lock" <<'PY'
import json, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg", "scripts/nogg").load_module()
data = {
    "pid": 12345,
    "host": "other-machine.invalid",
    "created_at": m.now()
}
open(sys.argv[1], "w").write(json.dumps(data) + "\n")
PY

( cd "$fx8" && NOGGING_ROOT="$fx8" "$nogg" recover ) >"$out" 2>&1 || { echo "FAIL - remote fresh recover exited non-zero"; cat "$out"; fail=1; }
check "remote fresh reports held (unverifiable)" "orchestrator.lock: held (unverifiable)"
refute "remote fresh has no attention item" "stale orchestrator.lock"

# 8b. Another host expired (created 100,000s ago, TTL 3600s) -> STALE
python3 - "$fx8/.nogging/locks/orchestrator.lock" <<'PY'
import json, sys
data = {
    "pid": 12345,
    "host": "other-machine.invalid",
    "created_at": "2026-10-10T10:00:00+00:00"
}
open(sys.argv[1], "w").write(json.dumps(data) + "\n")
PY

( cd "$fx8" && NOGGING_ROOT="$fx8" "$nogg" recover ) >"$out" 2>&1 && { echo "FAIL - remote expired recover should exit non-zero"; cat "$out"; fail=1; } || true
check "remote expired reports STALE" "orchestrator.lock: STALE"
check "remote expired flags attention" "stale orchestrator.lock"

# Reclaim remote expired without --force
NOGGING_ROOT="$fx8" python3 - "$nogg" <<'PY' >"$out" 2>&1
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg", sys.argv[1]).load_module()
m.acquire_orchestrator_lock()
print("ok remote expired reclaimed without --force")
PY
check "reclaim remote expired without --force" "ok remote expired reclaimed without --force"

if [[ $fail -ne 0 ]]; then
  echo "orchestrator-lock tests failed" >&2
  exit 1
fi
echo "all orchestrator-lock checks passed"
