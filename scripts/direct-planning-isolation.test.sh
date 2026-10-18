#!/usr/bin/env bash
# Verifies direct planning/Claude entry point isolation:
# - Generic test environment cleanup removes inherited exported NOGG_* and NOGGING_ROOT
# - Runs actual selected entry points directly:
#   * scripts/agents-boundary.test.sh
#   * scripts/acceptance.test.sh
#   * scripts/nogg.test.sh
# - Tests under role-only, name-only, and combined poisoned contexts
# - Verifies listening broker sentinel receives zero connections (including nogg.test.sh task-done fixtures)
# - Verifies fixture-supplied execution role triggers proper OpenSpec write refusal
# - Verifies forced plan-begin setup failure in nogg.test.sh reports all three scenarios by name and fails
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source generic test environment bootstrap
# shellcheck source=scripts/lib/test-env.sh
source "$root/scripts/lib/test-env.sh"

fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

work=$(mktemp -d)
cleanup() {
  if [[ -n "${broker_pid:-}" ]]; then
    kill "$broker_pid" 2>/dev/null || true
    wait "$broker_pid" 2>/dev/null || true
  fi
  python3 -c 'import shutil, sys; [shutil.rmtree(p, ignore_errors=True) for p in sys.argv[1:]]' \
    "$work" "${sentinel_dir:-}" "${forced_dir:-}" "${usage_home:-}"
}
trap cleanup EXIT

# 1. Isolated temporary quota source and npm cache
usage_home=$(mktemp -d)
mkdir -p "$usage_home/codex" "$usage_home/cache" "$usage_home/npm"
export CODEX_HOME="$usage_home/codex"
export XDG_CACHE_HOME="$usage_home/cache"
export NPM_CONFIG_CACHE="$usage_home/npm"
export AGY_NOGG_USAGE_PROBE=0

# 2. Broker Sentinel: listening Unix socket < 108 bytes
sentinel_dir=$(mktemp -d /tmp/nogg.XXXXXX)
sentinel_sock="$sentinel_dir/b.sock"
sentinel_log="$sentinel_dir/broker.log"
sentinel_ready="$sentinel_dir/broker.ready"
: >"$sentinel_log"

if [[ ${#sentinel_sock} -ge 108 ]]; then
  bad "sentinel socket path exceeds 108 bytes (${#sentinel_sock}): $sentinel_sock"
  exit 1
fi

python3 -c '
import os, socket, sys

sock_path = sys.argv[1]
log_path = sys.argv[2]
ready_path = sys.argv[3]

if os.path.exists(sock_path):
    os.remove(sock_path)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sock_path)
s.listen(10)

with open(ready_path, "w") as f:
    f.write("ready\n")

while True:
    try:
        conn, _ = s.accept()
        with open(log_path, "a") as f:
            f.write("hit\n")
        conn.close()
    except Exception:
        break
' "$sentinel_sock" "$sentinel_log" "$sentinel_ready" &
broker_pid=$!

for _ in {1..50}; do
  if [[ -f "$sentinel_ready" ]]; then break; fi
  sleep 0.05
done
if [[ ! -f "$sentinel_ready" ]]; then
  bad "broker sentinel failed to become ready"
  exit 1
fi
ok "broker sentinel listening on short socket (${#sentinel_sock} bytes)"

# 3. Direct execution under role-only poisoned context
parent_marker="keep_parent_role_only"
export PARENT_TEST_MARKER="$parent_marker"

child_out="$work/role_only.out"
if env \
  PARENT_TEST_MARKER="$parent_marker" \
  NOGG_SESSION_ROLE="lead" \
  bash "$root/scripts/agents-boundary.test.sh" >"$child_out" 2>&1; then
  ok "direct execution under role-only poisoned context succeeds"
else
  bad "direct execution under role-only poisoned context failed"
  cat "$child_out"
fi
[[ "${PARENT_TEST_MARKER:-}" == "$parent_marker" ]] || bad "parent marker lost after role-only test"

# 4. Direct execution under name-only poisoned context
child_out="$work/name_only.out"
if env \
  PARENT_TEST_MARKER="$parent_marker" \
  NOGG_SESSION_NAME="stale-foreign-session-name" \
  bash "$root/scripts/agents-boundary.test.sh" >"$child_out" 2>&1; then
  ok "direct execution under name-only poisoned context succeeds"
else
  bad "direct execution under name-only poisoned context failed"
  cat "$child_out"
fi
[[ "${PARENT_TEST_MARKER:-}" == "$parent_marker" ]] || bad "parent marker lost after name-only test"

# 5. Direct execution under combined poisoned context
# (role, name, authority, agent, invalid roots, fence markers, arbitrary future NOGG_*, broker sentinel)
child_out="$work/combined_agents.out"
if env \
  PARENT_TEST_MARKER="$parent_marker" \
  NOGG_SESSION_ROLE="restricted" \
  NOGG_SESSION_NAME="poisoned-lead-session" \
  NOGG_SESSION_AUTHORITY="restricted" \
  NOGG_SESSION_AGENT="codex" \
  NOGGING_ROOT="/invalid/bad/root/that/does/not/exist" \
  NOGG_SESSION_ROOT="/invalid/session/root" \
  NOGG_OPENSPEC_FENCED="1" \
  NOGG_OPENSPEC_FENCE="strict" \
  NOGG_FUTURE_FEATURE_XYZ="enabled" \
  NOGG_CUSTOM_VAR_999="custom_value" \
  NOGG_TASK_DONE_SOCKET="$sentinel_sock" \
  bash "$root/scripts/agents-boundary.test.sh" >"$child_out" 2>&1; then
  ok "direct execution of agents-boundary under combined poisoned context succeeds"
else
  bad "direct execution of agents-boundary under combined poisoned context failed"
  cat "$child_out"
fi

child_out="$work/combined_acceptance.out"
if env \
  PARENT_TEST_MARKER="$parent_marker" \
  NOGG_SESSION_ROLE="restricted" \
  NOGG_SESSION_NAME="poisoned-lead-session" \
  NOGG_SESSION_AUTHORITY="restricted" \
  NOGG_SESSION_AGENT="codex" \
  NOGGING_ROOT="/invalid/bad/root/that/does/not/exist" \
  NOGG_SESSION_ROOT="/invalid/session/root" \
  NOGG_OPENSPEC_FENCED="1" \
  NOGG_OPENSPEC_FENCE="strict" \
  NOGG_FUTURE_FEATURE_XYZ="enabled" \
  NOGG_CUSTOM_VAR_999="custom_value" \
  NOGG_TASK_DONE_SOCKET="$sentinel_sock" \
  bash "$root/scripts/acceptance.test.sh" >"$child_out" 2>&1; then
  ok "direct execution of acceptance under combined poisoned context succeeds"
else
  bad "direct execution of acceptance under combined poisoned context failed"
  cat "$child_out"
fi

child_out="$work/combined_nogg.out"
if env \
  PARENT_TEST_MARKER="$parent_marker" \
  NOGG_SESSION_ROLE="restricted" \
  NOGG_SESSION_NAME="poisoned-lead-session" \
  NOGG_SESSION_AUTHORITY="restricted" \
  NOGG_SESSION_AGENT="codex" \
  NOGGING_ROOT="/invalid/bad/root/that/does/not/exist" \
  NOGG_SESSION_ROOT="/invalid/session/root" \
  NOGG_OPENSPEC_FENCED="1" \
  NOGG_OPENSPEC_FENCE="strict" \
  NOGG_FUTURE_FEATURE_XYZ="enabled" \
  NOGG_CUSTOM_VAR_999="custom_value" \
  NOGG_TASK_DONE_SOCKET="$sentinel_sock" \
  bash "$root/scripts/nogg.test.sh" >"$child_out" 2>&1; then
  ok "direct execution of nogg.test.sh under combined poisoned context succeeds"
else
  bad "direct execution of nogg.test.sh under combined poisoned context failed"
  cat "$child_out"
fi

# 6. Verify broker sentinel received zero connections
if [[ -s "$sentinel_log" ]]; then
  bad "broker sentinel received connections during test execution"
  cat "$sentinel_log"
else
  ok "zero broker contacts made to listening sentinel (task-done fixtures isolated)"
fi

# 7. Deliberate execution denial fixture
fixture_root="$work/denial_fixture"
mkdir -p "$fixture_root/openspec/changes/demo" "$fixture_root/.nogging/locks"
git -C "$fixture_root" init -q
printf '{"planning_lock_ttl_seconds":7200}\n' >"$fixture_root/.nogging/config.json"
printf '{"pid":1,"host":"h","created_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
  >"$fixture_root/.nogging/locks/planning.lock"

denial_rc=0
denial_out=$(
  env -i PATH="$PATH" HOME="$HOME" \
    NOGG_INITIAL_POISON="poisoned" \
    bash -c '
      source "$1"
      export NOGG_SESSION_ROLE="execution"
      guard="$2"
      target_root="$3"
      printf "{\"tool_input\":{\"file_path\":\"openspec/changes/demo/spec.md\"}}" \
        | CLAUDE_PROJECT_DIR="$target_root" "$guard"
    ' -- "$root/scripts/lib/test-env.sh" "$root/scripts/hooks/pre-tool-use-openspec-guard" "$fixture_root" 2>&1
) || denial_rc=$?

[[ "$denial_rc" -eq 2 ]] \
  && ok "fixture deliberately supplying execution role triggers guard write refusal (exit 2)" \
  || bad "guard did not refuse write for fixture-supplied execution role (rc=$denial_rc): $denial_out"

plan_rc=0
plan_out=$(
  env -i PATH="$PATH" HOME="$HOME" \
    bash -c '
      source "$1"
      export NOGG_SESSION_ROLE="planning"
      guard="$2"
      target_root="$3"
      printf "{\"tool_input\":{\"file_path\":\"openspec/changes/demo/spec.md\"}}" \
        | CLAUDE_PROJECT_DIR="$target_root" "$guard"
    ' -- "$root/scripts/lib/test-env.sh" "$root/scripts/hooks/pre-tool-use-openspec-guard" "$fixture_root" 2>&1
) || plan_rc=$?

[[ "$plan_rc" -eq 0 ]] \
  && ok "fixture supplying planning role allows write (exit 0)" \
  || bad "guard blocked write for planning role (rc=$plan_rc): $plan_out"

# 8. Forced setup failure reporting by name in nogg.test.sh
forced_dir="$work/forced_setup"
mkdir -p "$forced_dir/scripts"

for item in "$root"/*; do
  bn="$(basename "$item")"
  if [[ "$bn" != "scripts" ]]; then
    ln -s "$item" "$forced_dir/$bn"
  fi
done
if [[ -d "$root/.nogging" ]]; then
  ln -s "$root/.nogging" "$forced_dir/.nogging"
fi

for s in "$root/scripts"/*; do
  sbn="$(basename "$s")"
  if [[ "$sbn" != "nogg" ]]; then
    ln -s "$s" "$forced_dir/scripts/$sbn"
  fi
done

cat >"$forced_dir/scripts/nogg" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "plan-begin" ]]; then
  echo "forced plan-begin setup failure" >&2
  exit 1
fi
exec "$root/scripts/nogg" "\$@"
EOF
chmod +x "$forced_dir/scripts/nogg"

forced_rc=0
forced_out=$(bash "$forced_dir/scripts/nogg.test.sh" 2>&1) || forced_rc=$?

[[ "$forced_rc" -ne 0 ]] \
  && ok "forced plan-begin failure causes nogg.test.sh to exit non-zero (rc=$forced_rc)" \
  || bad "nogg.test.sh exited 0 despite forced plan-begin setup failure"

echo "$forced_out" | grep -qF "FAIL - twb-bootstrap: plan-begin setup failed" \
  && ok "nogg.test.sh reports twb-bootstrap setup failure by name" \
  || bad "nogg.test.sh did not report twb-bootstrap setup failure by name"

echo "$forced_out" | grep -qF "FAIL - twb-doctor: plan-begin setup failed" \
  && ok "nogg.test.sh reports twb-doctor setup failure by name" \
  || bad "nogg.test.sh did not report twb-doctor setup failure by name"

echo "$forced_out" | grep -qF "FAIL - twb-guard: plan-begin setup failed" \
  && ok "nogg.test.sh reports twb-guard setup failure by name" \
  || bad "nogg.test.sh did not report twb-guard setup failure by name"

if echo "$forced_out" | grep -qF "ok   - twb-bootstrap: plan-begin opens the boundary"; then
  bad "dependent assertion ran for twb-bootstrap despite plan-begin failure"
else
  ok "dependent assertion skipped for twb-bootstrap"
fi

if echo "$forced_out" | grep -qF "ok   - twb-doctor: active planning session reported as OPEN"; then
  bad "dependent assertion ran for twb-doctor despite plan-begin failure"
else
  ok "dependent assertion skipped for twb-doctor"
fi

if echo "$forced_out" | grep -qF "ok   - twb-guard: guard allows an openspec/ write during a fresh planning session"; then
  bad "dependent assertion ran for twb-guard despite plan-begin failure"
else
  ok "dependent assertion skipped for twb-guard"
fi

if [[ $fail -ne 0 ]]; then
  echo "direct-planning-isolation checks failed" >&2
  exit 1
fi
echo "all direct-planning-isolation checks passed"
