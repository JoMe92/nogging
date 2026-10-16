#!/usr/bin/env bash
# Verifies test environment generic isolation:
# - arbitrary future NOGG_* names
# - all exported session, fence, broker and root context
# - unrelated-variable preservation
# - idempotence and nested cleanup
# - strict-shell (set -euo pipefail) and empty input
# - parent shell's unchanged environment
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/lib/test-env.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

test_env_script="$root/scripts/lib/test-env.sh"
[[ -f "$test_env_script" ]] || fail "scripts/lib/test-env.sh not found"

# 1. Empty input under strict shell
bash -c '
  set -euo pipefail
  test_env_script="$1"
  env -i PATH="$PATH" bash -c "
    set -euo pipefail
    source \"\$1\"
  " -- "$test_env_script"
' -- "$test_env_script" || fail "sourcing failed on empty environment under strict shell"

# 2. Arbitrary future NOGG_* names
bash -c '
  set -euo pipefail
  test_env_script="$1"
  env -i PATH="$PATH" \
    NOGG_FUTURE_FEATURE_XYZ="enabled" \
    NOGG_CUSTOM_99="value" \
    NOGG_ANOTHER_UNKNOWN="1" \
    bash -c "
      set -euo pipefail
      source \"\$1\"
      [[ -z \"\${NOGG_FUTURE_FEATURE_XYZ+x}\" ]] || exit 1
      [[ -z \"\${NOGG_CUSTOM_99+x}\" ]] || exit 1
      [[ -z \"\${NOGG_ANOTHER_UNKNOWN+x}\" ]] || exit 1
    " -- "$test_env_script"
' -- "$test_env_script" || fail "arbitrary future NOGG_* variables were not cleared"

# 3. All exported session, fence, broker and root context
bash -c '
  set -euo pipefail
  test_env_script="$1"
  env -i PATH="$PATH" \
    NOGGING_ROOT="/invalid/root" \
    NOGG_SESSION_NAME="test-session" \
    NOGG_SESSION_ROOT="/invalid/session/root" \
    NOGG_SESSION_ROLE="planning" \
    NOGG_SESSION_AGENT="codex" \
    NOGG_SESSION_AUTHORITY="trusted" \
    NOGG_TASK_DONE_SOCKET="/tmp/fake-broker.sock" \
    NOGG_OPENSPEC_FENCED="1" \
    NOGG_OPENSPEC_FENCE="strict" \
    bash -c "
      set -euo pipefail
      source \"\$1\"
      [[ -z \"\${NOGGING_ROOT+x}\" ]] || exit 1
      [[ -z \"\${NOGG_SESSION_NAME+x}\" ]] || exit 1
      [[ -z \"\${NOGG_SESSION_ROOT+x}\" ]] || exit 1
      [[ -z \"\${NOGG_SESSION_ROLE+x}\" ]] || exit 1
      [[ -z \"\${NOGG_SESSION_AGENT+x}\" ]] || exit 1
      [[ -z \"\${NOGG_SESSION_AUTHORITY+x}\" ]] || exit 1
      [[ -z \"\${NOGG_TASK_DONE_SOCKET+x}\" ]] || exit 1
      [[ -z \"\${NOGG_OPENSPEC_FENCED+x}\" ]] || exit 1
      [[ -z \"\${NOGG_OPENSPEC_FENCE+x}\" ]] || exit 1
    " -- "$test_env_script"
' -- "$test_env_script" || fail "exported session, fence, broker, or root context was not cleared"

# 4. Unrelated-variable preservation
bash -c '
  set -euo pipefail
  test_env_script="$1"
  env -i PATH="$PATH" HOME="/custom/home" \
    UNRELATED_SETTING="keep_this_intact" \
    XDG_CACHE_HOME="/custom/cache" \
    CODEX_HOME="/custom/codex" \
    NPM_CONFIG_CACHE="/custom/npm" \
    NOGG_TO_REMOVE="gone" \
    bash -c "
      set -euo pipefail
      source \"\$1\"
      [[ -z \"\${NOGG_TO_REMOVE+x}\" ]] || exit 1
      [[ \"\${UNRELATED_SETTING:-}\" == \"keep_this_intact\" ]] || exit 1
      [[ \"\${XDG_CACHE_HOME:-}\" == \"/custom/cache\" ]] || exit 1
      [[ \"\${CODEX_HOME:-}\" == \"/custom/codex\" ]] || exit 1
      [[ \"\${NPM_CONFIG_CACHE:-}\" == \"/custom/npm\" ]] || exit 1
      [[ \"\${HOME:-}\" == \"/custom/home\" ]] || exit 1
    " -- "$test_env_script"
' -- "$test_env_script" || fail "unrelated variables were not preserved"

# 5. Idempotence and nested cleanup
bash -c '
  set -euo pipefail
  test_env_script="$1"
  env -i PATH="$PATH" NOGG_INIT="1" bash -c "
    set -euo pipefail
    source \"\$1\"
    [[ -z \"\${NOGG_INIT+x}\" ]] || exit 1
    # Fixture sets its own variables after cleanup
    export NOGG_FIXTURE_A=\"fixture_val\"
    [[ \"\${NOGG_FIXTURE_A:-}\" == \"fixture_val\" ]] || exit 1
    # Nested cleanup sources test-env again
    source \"\$1\"
    [[ -z \"\${NOGG_FIXTURE_A+x}\" ]] || exit 1
    # Sourced again immediately when already clean
    source \"\$1\"
    [[ -z \"\${NOGG_FIXTURE_A+x}\" ]] || exit 1
  " -- "$test_env_script"
' -- "$test_env_script" || fail "idempotence or nested cleanup failed"

# 6. Parent shell environment preservation
parent_runner="$(mktemp)"
trap 'rm -f "$parent_runner"' EXIT
cat >"$parent_runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test_env_script="$1"

export PARENT_MARKER="parent_active"
export NOGGING_ROOT="/parent/root"
export NOGG_SESSION_NAME="parent-session"
export NOGG_FUTURE_KEY="parent-future-value"

# Run child in a subshell or separate process that sources test-env
child_result=$(
  bash -c '
    set -euo pipefail
    source "$1"
    [[ -z "${NOGGING_ROOT+x}" ]] || exit 1
    [[ -z "${NOGG_SESSION_NAME+x}" ]] || exit 1
    [[ -z "${NOGG_FUTURE_KEY+x}" ]] || exit 1
    [[ "${PARENT_MARKER:-}" == "parent_active" ]] || exit 1
    echo "child_ok"
  ' -- "$test_env_script"
)

[[ "$child_result" == "child_ok" ]] || exit 2

# Verify parent environment remains unchanged
[[ "${PARENT_MARKER:-}" == "parent_active" ]] || exit 3
[[ "${NOGGING_ROOT:-}" == "/parent/root" ]] || exit 4
[[ "${NOGG_SESSION_NAME:-}" == "parent-session" ]] || exit 5
[[ "${NOGG_FUTURE_KEY:-}" == "parent-future-value" ]] || exit 6
echo "parent_ok"
EOF
chmod +x "$parent_runner"

parent_out=$(bash "$parent_runner" "$test_env_script") || fail "parent runner execution failed"
[[ "$parent_out" == "parent_ok" ]] || fail "parent shell environment was altered by child test-env bootstrap"

# 7. Values with spaces, quotes, empty string, or complex characters
bash -c '
  set -euo pipefail
  test_env_script="$1"
  env -i PATH="$PATH" \
    NOGG_EMPTY="" \
    NOGG_SPACES="has some spaces" \
    NOGG_QUOTES="\"double\" and '\''single'\''" \
    bash -c "
      set -euo pipefail
      source \"\$1\"
      [[ -z \"\${NOGG_EMPTY+x}\" ]] || exit 1
      [[ -z \"\${NOGG_SPACES+x}\" ]] || exit 1
      [[ -z \"\${NOGG_QUOTES+x}\" ]] || exit 1
    " -- "$test_env_script"
' -- "$test_env_script" || fail "variables with spaces, quotes, or empty string were not cleared"

printf 'test environment generic bootstrap: ok\n'
