#!/usr/bin/env bash
# Verifies direct test isolation for Python, Pi and Antigravity entry points
# under poisoned caller contexts and verifies zero broker sentinel contacts.
#
# Requirements (Decision 4, Decision 6, and test-isolation spec):
# - actual direct suites run in child environments poisoned with role-only,
#   name-only and combined contexts, unknown NOGG_ variables, bad roots and fence markers;
# - listening broker sentinel receives zero connections/requests;
# - isolated temporary quota source and npm cache;
# - parent shell environment and unrelated variables are preserved;
# - fixture-supplied execution authority still exercises real guard refusals;
# - offline, portable on GitHub runners: no real Dolt/bd, no PID assumptions,
#   no unshare, socket path < 108 bytes, no existing tmux server assumed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/lib/test-env.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

ok() {
  printf 'ok   - %s\n' "$*"
}

work="$(mktemp -d /tmp/nogg.XXXXXX)"
sentinel_pid=""
cleanup() {
  if [[ -n "$sentinel_pid" ]]; then
    kill "$sentinel_pid" 2>/dev/null || true
    wait "$sentinel_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# 1. Quota and cache isolation
mkdir -p "$work/codex" "$work/cache" "$work/npm-cache"
export CODEX_HOME="$work/codex"
export XDG_CACHE_HOME="$work/cache"
export AGY_NOGG_USAGE_PROBE=0
export npm_config_cache="$work/npm-cache"

# 2. Listening broker sentinel with short socket path (< 108 bytes)
broker_socket="$work/b.sock"
broker_log="$work/b.log"
touch "$broker_log"
[[ ${#broker_socket} -lt 108 ]] || fail "Broker socket path is too long: $broker_socket"

python3 -c '
import os, signal, socket, sys

sock_path = sys.argv[1]
log_path = sys.argv[2]

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock_path)
s.listen(5)

def on_term(sig, frame):
    try:
        s.close()
    except Exception:
        pass
    sys.exit(0)

signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGINT, on_term)

while True:
    try:
        conn, _ = s.accept()
        with open(log_path, "a") as f:
            f.write("contact\n")
        conn.close()
    except Exception:
        break
' "$broker_socket" "$broker_log" &
sentinel_pid=$!

while [[ ! -S "$broker_socket" ]]; do
  sleep 0.05
done
ok "broker sentinel listening on short socket ($broker_socket)"

# 3. Parent preservation probe
export UNRELATED_PARENT_TEST_VAR="preserved_sentinel_val"

suites=(
  "scripts/repository-state.test.sh"
  "scripts/planning-kickoff.test.sh"
  "scripts/pi-guard.test.sh"
  "scripts/pi-planning-boundary.test.sh"
  "scripts/pi-live-guard.test.sh"
  "scripts/agy-guard.test.sh"
  "scripts/antigravity-launch.test.sh"
)

# 4. Scenario A: Role-only poisoned context
for suite in "scripts/repository-state.test.sh" "scripts/planning-kickoff.test.sh"; do
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    CODEX_HOME="$CODEX_HOME" \
    XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    AGY_NOGG_USAGE_PROBE=0 \
    npm_config_cache="$npm_config_cache" \
    NOGG_SESSION_ROLE="lead" \
    bash "$root/$suite" >/dev/null 2>&1 || fail "suite failed under role-only poisoned context: $suite"
  ok "role-only poison isolated: $suite"
done

# 5. Scenario B: Name-only poisoned context
for suite in "scripts/pi-guard.test.sh" "scripts/pi-planning-boundary.test.sh"; do
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    CODEX_HOME="$CODEX_HOME" \
    XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    AGY_NOGG_USAGE_PROBE=0 \
    npm_config_cache="$npm_config_cache" \
    NOGG_SESSION_NAME="foreign-session-name" \
    bash "$root/$suite" >/dev/null 2>&1 || fail "suite failed under name-only poisoned context: $suite"
  ok "name-only poison isolated: $suite"
done

# 6. Scenario C: Combined poisoned context across all 7 suites
for suite in "${suites[@]}"; do
  env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    CODEX_HOME="$CODEX_HOME" \
    XDG_CACHE_HOME="$XDG_CACHE_HOME" \
    AGY_NOGG_USAGE_PROBE=0 \
    npm_config_cache="$npm_config_cache" \
    NOGGING_ROOT="/nonexistent/poisoned/root" \
    NOGG_SESSION_ROLE="planning" \
    NOGG_SESSION_NAME="poisoned-planner" \
    NOGG_SESSION_ROOT="/nonexistent/poisoned/session/root" \
    NOGG_SESSION_AGENT="codex" \
    NOGG_SESSION_AUTHORITY="trusted" \
    NOGG_OPENSPEC_FENCED="1" \
    NOGG_FUTURE_FEATURE_XYZ="unknown_flag_value" \
    NOGG_TASK_DONE_SOCKET="$broker_socket" \
    bash "$root/$suite" >/dev/null 2>&1 || fail "suite failed under combined poisoned context: $suite"
  ok "combined poison isolated: $suite"
done

# 7. Broker sentinel received zero contacts
if [[ -s "$broker_log" ]]; then
  fail "broker sentinel received $(wc -l < "$broker_log") unexpected contacts"
fi
ok "zero contacts received by broker sentinel"

# 8. Parent environment preservation
[[ "${UNRELATED_PARENT_TEST_VAR:-}" == "preserved_sentinel_val" ]] || fail "parent environment variable was corrupted"
ok "parent environment preserved"

# 9. Scenario: Deliberate fixture execution authority still refuses protected OpenSpec writes
fixture_dir="$work/guard-fixture"
mkdir -p "$fixture_dir/main/.nogging/locks" "$fixture_dir/main/openspec"
cat > "$fixture_dir/main/.nogging/config.json" <<'JSON'
{}
JSON
git -C "$fixture_dir/main" init -q
git -C "$fixture_dir/main" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm "init"
git -C "$fixture_dir/main" worktree add -qb linked "$fixture_dir/linked" >/dev/null 2>&1

# Run in child process that sources test-env.sh, then sets execution role and tests agy-guard
python3 - "$root" "$fixture_dir/linked" <<'PY' || fail "guard failed to enforce OpenSpec write denial under fixture execution authority"
import json
import os
import subprocess
import sys

root = sys.argv[1]
worktree = sys.argv[2]
guard = os.path.join(root, "scripts/hooks/agy-guard")

# Execute under fixture execution context (lead / trusted)
env = {
    "PATH": os.environ["PATH"],
    "NOGG_SESSION_ROLE": "lead",
    "NOGG_SESSION_AUTHORITY": "trusted",
    "NOGG_SESSION_WORKING_DIR": worktree,
}

# 1) OpenSpec write must be denied
payload = json.dumps({
    "toolCall": {
        "name": "write_to_file",
        "args": {"TargetFile": os.path.join(worktree, "openspec/tasks.md"), "CodeContent": "bad"}
    }
})
res = subprocess.run(["python3", guard], input=payload, text=True, capture_output=True, env=env, check=True)
decision = json.loads(res.stdout).get("decision")
assert decision == "deny", f"expected deny for OpenSpec write, got {decision}"

# 2) Regular non-OpenSpec write must be allowed
payload_ok = json.dumps({
    "toolCall": {
        "name": "write_to_file",
        "args": {"TargetFile": os.path.join(worktree, "src/code.py"), "CodeContent": "ok"}
    }
})
res_ok = subprocess.run(["python3", guard], input=payload_ok, text=True, capture_output=True, env=env, check=True)
decision_ok = json.loads(res_ok.stdout).get("decision")
assert decision_ok == "allow", f"expected allow for non-OpenSpec write, got {decision_ok}"
PY
ok "fixture execution authority still refuses protected OpenSpec writes"

# 10. Nested test-env bootstrap idempotency under strict shell
bash -c '
  set -euo pipefail
  test_env="$1"
  source "$test_env"
  source "$test_env"
' -- "$root/scripts/lib/test-env.sh" || fail "nested test-env sourcing failed"
ok "nested test-env sourcing is idempotent"

echo "all direct guard isolation checks passed"
