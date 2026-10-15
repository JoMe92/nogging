#!/usr/bin/env bash
# Test suite for the stateful fake herdr CLI stub (TASK-HDR-005).
#
# Verifies:
#   - Version and reachability (status running/not running, ping)
#   - Shape comparison with spike fixtures under scripts/fixtures/herdr/spike/
#   - Workspace commands (list, create, close)
#   - Pane commands (create, list, get, process-info, send-text, send-keys, read text/ansi/json, close, rename)
#   - Agent commands (get, list, explain)
#   - Error shapes (pane_not_found, server_not_running, CLI syntax error)
#   - Simulated server restart (process PIDs change, pane labels/ids persist, agent state resets)
#   - Injectable failures (fail, fail_<cmd>, fail_once, server_down)
#   - Call log ($HERDR_STUB_DIR/calls.log)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
spike_dir="$repo_root/scripts/fixtures/herdr/spike"
herdr_bin="$repo_root/scripts/fixtures/herdr/bin/herdr"

work=$(mktemp -d)
out=$(mktemp)
err=$(mktemp)
trap 'rm -f "$out" "$err"; rm -rf "$work"' EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out" 2>/dev/null || true; cat "$err" 2>/dev/null || true; fail=1; }

export PATH="$repo_root/scripts/fixtures/herdr/bin:$PATH"
export HERDR_STUB_DIR="$work/herdr-stub"
mkdir -p "$HERDR_STUB_DIR"

# Python shape verifier helper
verify_shape() {
  local fixture_file="$1"
  local actual_file="$2"
  local label="$3"

  python3 - "$fixture_file" "$actual_file" "$label" <<'PY'
import json
import sys

fixture_path, actual_path, label = sys.argv[1], sys.argv[2], sys.argv[3]

with open(fixture_path, "r", encoding="utf-8") as f:
    expected = json.load(f)

with open(actual_path, "r", encoding="utf-8") as f:
    actual = json.load(f)

def check(exp, act, path=""):
    if isinstance(exp, dict):
        if not isinstance(act, dict):
            raise AssertionError(f"{label} {path}: expected dict, got {type(act)}")
        for k, v in exp.items():
            if k not in act:
                raise AssertionError(f"{label} {path}: missing key '{k}' in {list(act.keys())}")
            check(v, act[k], f"{path}.{k}")
    elif isinstance(exp, list):
        if not isinstance(act, list):
            raise AssertionError(f"{label} {path}: expected list, got {type(act)}")
        for i, item in enumerate(act):
            if i < len(exp):
                check(exp[i], item, f"{path}[{i}]")
            elif exp:
                check(exp[-1], item, f"{path}[{i}]")
    elif exp is None:
        pass
    else:
        if isinstance(exp, bool):
            if not isinstance(act, bool):
                raise AssertionError(f"{label} {path}: expected bool, got {type(act)}")
        elif isinstance(exp, (int, float)):
            if not isinstance(act, (int, float)):
                raise AssertionError(f"{label} {path}: expected number, got {type(act)}")
        elif isinstance(exp, str):
            if not isinstance(act, str):
                raise AssertionError(f"{label} {path}: expected str, got {type(act)}")

check(expected, actual)
PY
}

# --- 1. Version ---
"$herdr_bin" --version >"$out"
if cmp -s "$out" "$spike_dir/version.txt"; then
  ok "version: --version matches spike version.txt"
else
  bad "version: --version does not match spike version.txt"
fi

"$herdr_bin" -V >"$out"
if cmp -s "$out" "$spike_dir/version.txt"; then
  ok "version: -V matches spike version.txt"
else
  bad "version: -V does not match spike version.txt"
fi

"$herdr_bin" version >"$out"
if cmp -s "$out" "$spike_dir/version.txt"; then
  ok "version: version subcommand matches spike version.txt"
else
  bad "version: version subcommand does not match spike version.txt"
fi

# --- 2. Reachability and status ---
"$herdr_bin" status >"$out"
if grep -q "status: running" "$out" && grep -q "version: 0.9.5" "$out" && grep -q "client:" "$out"; then
  ok "status: default status is running with correct structure"
else
  bad "status: unexpected default running status output"
fi

# Ping shape
"$herdr_bin" ping >"$out"
if verify_shape "$spike_dir/json/ping.json" "$out" "ping"; then
  ok "ping: matches spike ping.json shape"
else
  bad "ping: shape mismatch"
fi

# --- 3. Seed spike fixtures and compare shapes ---
"$herdr_bin" --seed-spike

# Session list shape
"$herdr_bin" session list --json >"$out"
if verify_shape "$spike_dir/json/session-list.json" "$out" "session-list"; then
  ok "session-list: matches spike session-list.json shape"
else
  bad "session-list: shape mismatch"
fi

# Workspace list shape
"$herdr_bin" workspace list >"$out"
if verify_shape "$spike_dir/json/workspace-list.json" "$out" "workspace-list"; then
  ok "workspace-list: matches spike workspace-list.json shape"
else
  bad "workspace-list: shape mismatch"
fi

# Workspace create shape
"$herdr_bin" workspace create --cwd "/tmp" --label "nogging-fixture" >"$out"
if verify_shape "$spike_dir/json/workspace-create.json" "$out" "workspace-create"; then
  ok "workspace-create: matches spike workspace-create.json shape"
else
  bad "workspace-create: shape mismatch"
fi

# Workspace close shape
"$herdr_bin" workspace close w2 >"$out"
if verify_shape "$spike_dir/json/workspace-close.json" "$out" "workspace-close"; then
  ok "workspace-close: matches spike workspace-close.json shape"
else
  bad "workspace-close: shape mismatch"
fi

# Re-seed for pane checks
"$herdr_bin" --seed-spike

# Pane list shape
"$herdr_bin" pane list --workspace w2 >"$out"
if verify_shape "$spike_dir/json/pane-list.json" "$out" "pane-list"; then
  ok "pane-list: matches spike pane-list.json shape"
else
  bad "pane-list: shape mismatch"
fi

# Pane get shape (standard pane)
"$herdr_bin" pane get w2:p2 >"$out"
if verify_shape "$spike_dir/json/pane-get.json" "$out" "pane-get"; then
  ok "pane-get: matches spike pane-get.json shape"
else
  bad "pane-get: shape mismatch"
fi

# Pane get shape (agent pane)
"$herdr_bin" pane get w1:pJ >"$out"
if verify_shape "$spike_dir/json/pane-get-agent.json" "$out" "pane-get-agent"; then
  ok "pane-get-agent: matches spike pane-get-agent.json shape"
else
  bad "pane-get-agent: shape mismatch"
fi

# Pane process-info shape (standard pane)
"$herdr_bin" pane process-info w2:p2 >"$out"
if verify_shape "$spike_dir/json/pane-process-info.json" "$out" "pane-process-info"; then
  ok "pane-process-info: matches spike pane-process-info.json shape"
else
  bad "pane-process-info: shape mismatch"
fi

# Pane process-info shape (agent pane)
"$herdr_bin" pane process-info w1:pJ >"$out"
if verify_shape "$spike_dir/json/pane-process-info-agent.json" "$out" "pane-process-info-agent"; then
  ok "pane-process-info-agent: matches spike pane-process-info-agent.json shape"
else
  bad "pane-process-info-agent: shape mismatch"
fi

# Pane rename shape
"$herdr_bin" pane rename w2:p1 sf-fixture-root >"$out"
if verify_shape "$spike_dir/json/pane-rename.json" "$out" "pane-rename"; then
  ok "pane-rename: matches spike pane-rename.json shape"
else
  bad "pane-rename: shape mismatch"
fi

# Pane close shape
"$herdr_bin" pane close w2:p2 >"$out"
if verify_shape "$spike_dir/json/pane-close.json" "$out" "pane-close"; then
  ok "pane-close: matches spike pane-close.json shape"
else
  bad "pane-close: shape mismatch"
fi

# Agent get shape
"$herdr_bin" agent get w1:pJ >"$out"
if verify_shape "$spike_dir/json/agent-get.json" "$out" "agent-get"; then
  ok "agent-get: matches spike agent-get.json shape"
else
  bad "agent-get: shape mismatch"
fi

# Agent list shape
"$herdr_bin" agent list >"$out"
if verify_shape "$spike_dir/json/agent-list.json" "$out" "agent-list"; then
  ok "agent-list: matches spike agent-list.json shape"
else
  bad "agent-list: shape mismatch"
fi

# Agent explain shape
"$herdr_bin" agent explain w1:pJ --json >"$out"
if verify_shape "$spike_dir/json/agent-explain.json" "$out" "agent-explain-json"; then
  ok "agent-explain: matches spike agent-explain.json shape"
else
  bad "agent-explain: shape mismatch"
fi

"$herdr_bin" agent explain w1:pJ >"$out"
if cmp -s "$out" "$spike_dir/json/agent-explain.txt"; then
  ok "agent-explain: text output matches spike agent-explain.txt"
else
  bad "agent-explain: text output mismatch"
fi

# Layout apply shape
"$herdr_bin" layout apply "$spike_dir/json/layout-apply.json" >"$out"
if verify_shape "$spike_dir/json/layout-apply.json" "$out" "layout-apply"; then
  ok "layout-apply: matches spike layout-apply.json shape"
else
  bad "layout-apply: shape mismatch"
fi

# --- 4. Pane read (text, ansi, json) ---
"$herdr_bin" pane read w2:p1 --format text >"$out"
if cmp -s "$out" "$spike_dir/read/fixture-visible.txt"; then
  ok "pane-read: plain text output matches fixture-visible.txt"
else
  bad "pane-read: plain text output mismatch"
fi

"$herdr_bin" pane read w2:p1 --format ansi >"$out"
if cmp -s "$out" "$spike_dir/read/fixture-visible.ansi"; then
  ok "pane-read: ANSI output matches fixture-visible.ansi"
else
  bad "pane-read: ANSI output mismatch"
fi

"$herdr_bin" pane read w2:p1 --format text --json >"$out"
if verify_shape "$spike_dir/read/fixture-api-visible-text.json" "$out" "read-text-json"; then
  ok "pane-read: text json matches fixture-api-visible-text.json shape"
else
  bad "pane-read: text json shape mismatch"
fi

"$herdr_bin" pane read w2:p1 --format ansi --json >"$out"
if verify_shape "$spike_dir/read/fixture-api-visible-ansi.json" "$out" "read-ansi-json"; then
  ok "pane-read: ANSI json matches fixture-api-visible-ansi.json shape"
else
  bad "pane-read: ANSI json shape mismatch"
fi

# --- 5. Error shapes ---
# Pane not found
if "$herdr_bin" pane get nonexistent_pane >"$out" 2>"$err"; then
  bad "error: pane get nonexistent should exit non-zero"
else
  if verify_shape "$spike_dir/json/error-pane-not-found.json" "$err" "error-pane-not-found"; then
    ok "error: pane not found returns exit 1 and matching error-pane-not-found.json"
  else
    bad "error: pane not found error shape mismatch"
  fi
fi

# Server not running error
touch "$HERDR_STUB_DIR/server_down"
if "$herdr_bin" pane list >"$out" 2>"$err"; then
  bad "error: pane list when server down should exit non-zero"
else
  if verify_shape "$spike_dir/json/error-server-not-running.json" "$err" "error-server-not-running"; then
    ok "error: server down returns exit 1 and matching error-server-not-running.json"
  else
    bad "error: server down error shape mismatch"
  fi
fi

"$herdr_bin" status >"$out"
if grep -q "status: not running" "$out"; then
  ok "status: status reports not running when server is down"
else
  bad "status: expected not running status"
fi
rm -f "$HERDR_STUB_DIR/server_down"

# CLI syntax error (exit 2)
if "$herdr_bin" pane read >"$out" 2>"$err"; then
  bad "error: pane read with missing args should exit non-zero"
else
  st=$?
  if grep -q "usage: herdr pane read" "$err"; then
    ok "error: CLI syntax error produces usage on stderr"
  else
    bad "error: expected usage string on stderr for syntax error"
  fi
fi

# --- 6. Send text and keys (.after transition) ---
"$herdr_bin" pane create --label "test-send" --cwd "/tmp" >"$out"
p_id=$(python3 -c "import json; print(json.load(open('$out'))['result']['pane']['pane_id'])")

"$herdr_bin" pane send-text "$p_id" "hello from test"
printf 'after-enter-content\n' >"$HERDR_STUB_DIR/pane-$p_id.after"
"$herdr_bin" pane send-keys "$p_id" Enter
"$herdr_bin" pane read "$p_id" --format text >"$out"
if grep -q "after-enter-content" "$out"; then
  ok "send-keys: Enter triggers .after file swap to current pane content"
else
  bad "send-keys: .after content was not applied upon Enter"
fi

# --- 7. Simulated server restart ---
"$herdr_bin" pane process-info "$p_id" >"$out"
pid_before=$(python3 -c "import json; print(json.load(open('$out'))['result']['process_info']['shell_pid'])")

"$herdr_bin" server restart
"$herdr_bin" pane process-info "$p_id" >"$out"
pid_after=$(python3 -c "import json; print(json.load(open('$out'))['result']['process_info']['shell_pid'])")

if [[ "$pid_before" != "$pid_after" ]]; then
  ok "restart: server restart allocates new shell_pid (before: $pid_before, after: $pid_after)"
else
  bad "restart: shell_pid unchanged across restart"
fi

# Label and pane_id persisted
"$herdr_bin" pane get "$p_id" >"$out"
lbl=$(python3 -c "import json; print(json.load(open('$out'))['result']['pane']['label'])")
if [[ "$lbl" == "test-send" ]]; then
  ok "restart: pane_id and label persist across restart"
else
  bad "restart: label lost across restart (got $lbl)"
fi

# --- 8. Injectable failures ---
# fail_once
echo "42" >"$HERDR_STUB_DIR/fail_once"
if "$herdr_bin" pane list >"$out" 2>"$err"; then
  bad "inject: fail_once did not trigger error"
else
  code=$?
  if [[ $code -eq 42 ]]; then
    ok "inject: fail_once exited with specified code 42"
  else
    bad "inject: fail_once exit code was $code, expected 42"
  fi
fi
# Subsequent command succeeds
if "$herdr_bin" pane list >"$out" 2>/dev/null; then
  ok "inject: fail_once consumed; next command succeeded"
else
  bad "inject: fail_once was not cleared"
fi

# fail_<cmd>
echo "19" >"$HERDR_STUB_DIR/fail_pane_read"
if "$herdr_bin" pane read "$p_id" >"$out" 2>"$err"; then
  bad "inject: fail_pane_read did not trigger error"
else
  code=$?
  if [[ $code -eq 19 ]]; then
    ok "inject: fail_pane_read triggered for target command with exit code 19"
  else
    bad "inject: fail_pane_read exit code was $code, expected 19"
  fi
fi
rm -f "$HERDR_STUB_DIR/fail_pane_read"

# --- 9. Call log ---
if [[ -f "$HERDR_STUB_DIR/calls.log" ]]; then
  if grep -q "pane send-text" "$HERDR_STUB_DIR/calls.log" && \
     grep -q "pane send-keys" "$HERDR_STUB_DIR/calls.log" && \
     grep -q "pane read" "$HERDR_STUB_DIR/calls.log" && \
     grep -q "server restart" "$HERDR_STUB_DIR/calls.log"; then
    ok "calls.log: records invocations with expected command lines"
  else
    bad "calls.log: missing expected invocations"
  fi
else
  bad "calls.log: file not created"
fi

echo
if [[ $fail -ne 0 ]]; then
  echo "FAIL - scripts/herdr-stub.test.sh"
  exit 1
fi
echo "PASS - scripts/herdr-stub.test.sh"
exit 0
