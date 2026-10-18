#!/usr/bin/env bash
# Test suite for the stateful fake herdr CLI and socket server (TASK-HDR-014).
#
# Verifies Decision 14:
#   - Version and reachability (status running/not running)
#   - Real CLI parity: synthetic forms (layout apply, pane create,
#     pane split --command, ping, api ping, server start/run/restart,
#     --seed-spike, --simulate-restart) fail with usage, exit 2
#   - Test controls off the CLI ($HERDR_STUB_DIR control files)
#   - Real local 0600 Unix socket server (layout.apply on shared state)
#   - Opt-in real pane process and termination on pane close
#   - Socket faults (refused, drop reply, workspace_not_found, permissions,
#     symlink, non-socket)
#   - Path length limit (>= 108 bytes fails to bind)
#   - Shape comparison with spike fixtures under scripts/fixtures/herdr/spike/
#   - Workspace commands (list, create, close)
#   - Pane commands (list, get, process-info, send-text, send-keys, read, close, rename)
#   - Agent commands (get, list, explain)
#   - Error shapes (pane_not_found, server_not_running, CLI syntax error)
#   - Simulated server restart (process PIDs change, pane labels/ids persist)
#   - Injectable failures (fail, fail_<cmd>, fail_once, server_down)
#   - Call log with redacted env values
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
spike_dir="$repo_root/scripts/fixtures/herdr/spike"
herdr_bin="$repo_root/scripts/fixtures/herdr/bin/herdr"
control_bin="$repo_root/scripts/fixtures/herdr/bin/herdr-stub-control"

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

# Helper to send a socket request line and write response to stdout
send_socket_request() {
  local socket_path="$1"
  local req_json="$2"

  python3 - "$socket_path" "$req_json" <<'PY'
import json
import socket
import sys

sock_path, payload = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(5.0)
s.connect(sock_path)
s.sendall((payload.strip() + "\n").encode("utf-8"))
f = s.makefile("r", encoding="utf-8")
resp = f.readline()
s.close()
if resp:
    sys.stdout.write(resp)
PY
}

# --- 1. Version ---
"$herdr_bin" --version >"$out" 2>"$err"
if cmp -s "$out" "$spike_dir/version.txt"; then
  ok "version: --version matches spike version.txt"
else
  bad "version: --version does not match spike version.txt"
fi

"$herdr_bin" -V >"$out" 2>"$err"
if cmp -s "$out" "$spike_dir/version.txt"; then
  ok "version: -V matches spike version.txt"
else
  bad "version: -V does not match spike version.txt"
fi

"$herdr_bin" version >"$out" 2>"$err"
if cmp -s "$out" "$spike_dir/version.txt"; then
  ok "version: version subcommand matches spike version.txt"
else
  bad "version: version subcommand does not match spike version.txt"
fi

# --- 2. Reachability and status ---
"$herdr_bin" status >"$out" 2>"$err"
if grep -q "status: running" "$out" && grep -q "version: 0.9.5" "$out" && grep -q "client:" "$out"; then
  ok "status: default status is running with correct structure"
else
  bad "status: unexpected default running status output"
fi

# --- 3. CLI parity: synthetic forms fail with usage, exit 2 ---
assert_synthetic_exit2() {
  local desc="$1"
  shift
  set +e
  "$herdr_bin" "$@" >"$out" 2>"$err"
  local code=$?
  set -e
  if [[ $code -eq 2 ]] && grep -qi "usage:" "$err"; then
    ok "parity: synthetic form '$desc' exits 2 with usage on stderr"
  else
    bad "parity: synthetic form '$desc' failed to exit 2 with usage (exit=$code)"
  fi
}

assert_synthetic_exit2 "layout apply" layout apply "$spike_dir/json/layout-apply.json"
assert_synthetic_exit2 "pane create" pane create --label "bad" --cwd "/tmp"
assert_synthetic_exit2 "pane split --command" pane split --command sleep 300
assert_synthetic_exit2 "ping" ping
assert_synthetic_exit2 "api ping" api ping
assert_synthetic_exit2 "server start" server start
assert_synthetic_exit2 "server run" server run
assert_synthetic_exit2 "server restart" server restart
assert_synthetic_exit2 "--seed-spike flag" --seed-spike
assert_synthetic_exit2 "--simulate-restart flag" --simulate-restart

# --- 4. Seed spike fixtures via control file and compare shapes ---
touch "$HERDR_STUB_DIR/seed_spike"

# Session list shape
"$herdr_bin" session list --json >"$out" 2>"$err"
if verify_shape "$spike_dir/json/session-list.json" "$out" "session-list"; then
  ok "session-list: matches spike session-list.json shape"
else
  bad "session-list: shape mismatch"
fi

# Workspace list shape
"$herdr_bin" workspace list >"$out" 2>"$err"
if verify_shape "$spike_dir/json/workspace-list.json" "$out" "workspace-list"; then
  ok "workspace-list: matches spike workspace-list.json shape"
else
  bad "workspace-list: shape mismatch"
fi

# Workspace create shape
"$herdr_bin" workspace create --cwd "/tmp" --label "nogging-fixture" >"$out" 2>"$err"
if verify_shape "$spike_dir/json/workspace-create.json" "$out" "workspace-create"; then
  ok "workspace-create: matches spike workspace-create.json shape"
else
  bad "workspace-create: shape mismatch"
fi

# Workspace close shape
"$herdr_bin" workspace close w2 >"$out" 2>"$err"
if verify_shape "$spike_dir/json/workspace-close.json" "$out" "workspace-close"; then
  ok "workspace-close: matches spike workspace-close.json shape"
else
  bad "workspace-close: shape mismatch"
fi

# Re-seed for pane checks
"$control_bin" seed-spike

# Pane list shape
"$herdr_bin" pane list --workspace w2 >"$out" 2>"$err"
if verify_shape "$spike_dir/json/pane-list.json" "$out" "pane-list"; then
  ok "pane-list: matches spike pane-list.json shape"
else
  bad "pane-list: shape mismatch"
fi

# Pane get shape (standard pane)
"$herdr_bin" pane get w2:p2 >"$out" 2>"$err"
if verify_shape "$spike_dir/json/pane-get.json" "$out" "pane-get"; then
  ok "pane-get: matches spike pane-get.json shape"
else
  bad "pane-get: shape mismatch"
fi

# Pane get shape (agent pane)
"$herdr_bin" pane get w1:pJ >"$out" 2>"$err"
if verify_shape "$spike_dir/json/pane-get-agent.json" "$out" "pane-get-agent"; then
  ok "pane-get-agent: matches spike pane-get-agent.json shape"
else
  bad "pane-get-agent: shape mismatch"
fi

# Pane process-info shape (standard pane)
"$herdr_bin" pane process-info w2:p2 >"$out" 2>"$err"
if verify_shape "$spike_dir/json/pane-process-info.json" "$out" "pane-process-info"; then
  ok "pane-process-info: matches spike pane-process-info.json shape"
else
  bad "pane-process-info: shape mismatch"
fi

# Pane process-info shape (agent pane)
"$herdr_bin" pane process-info w1:pJ >"$out" 2>"$err"
if verify_shape "$spike_dir/json/pane-process-info-agent.json" "$out" "pane-process-info-agent"; then
  ok "pane-process-info-agent: matches spike pane-process-info-agent.json shape"
else
  bad "pane-process-info-agent: shape mismatch"
fi

# Pane rename shape
"$herdr_bin" pane rename w2:p1 sf-fixture-root >"$out" 2>"$err"
if verify_shape "$spike_dir/json/pane-rename.json" "$out" "pane-rename"; then
  ok "pane-rename: matches spike pane-rename.json shape"
else
  bad "pane-rename: shape mismatch"
fi

# Pane close shape
"$herdr_bin" pane close w2:p2 >"$out" 2>"$err"
if verify_shape "$spike_dir/json/pane-close.json" "$out" "pane-close"; then
  ok "pane-close: matches spike pane-close.json shape"
else
  bad "pane-close: shape mismatch"
fi

# Agent get shape
"$herdr_bin" agent get w1:pJ >"$out" 2>"$err"
if verify_shape "$spike_dir/json/agent-get.json" "$out" "agent-get"; then
  ok "agent-get: matches spike agent-get.json shape"
else
  bad "agent-get: shape mismatch"
fi

# Agent list shape
"$herdr_bin" agent list >"$out" 2>"$err"
if verify_shape "$spike_dir/json/agent-list.json" "$out" "agent-list"; then
  ok "agent-list: matches spike agent-list.json shape"
else
  bad "agent-list: shape mismatch"
fi

# Agent explain shape
"$herdr_bin" agent explain w1:pJ --json >"$out" 2>"$err"
if verify_shape "$spike_dir/json/agent-explain.json" "$out" "agent-explain-json"; then
  ok "agent-explain: matches spike agent-explain.json shape"
else
  bad "agent-explain: shape mismatch"
fi

"$herdr_bin" agent explain w1:pJ >"$out" 2>"$err"
if cmp -s "$out" "$spike_dir/json/agent-explain.txt"; then
  ok "agent-explain: text output matches spike agent-explain.txt"
else
  bad "agent-explain: text output mismatch"
fi

# --- 5. Pane read (text, ansi, json) ---
"$herdr_bin" pane read w2:p1 --format text >"$out" 2>"$err"
if cmp -s "$out" "$spike_dir/read/fixture-visible.txt"; then
  ok "pane-read: plain text output matches fixture-visible.txt"
else
  bad "pane-read: plain text output mismatch"
fi

"$herdr_bin" pane read w2:p1 --format ansi >"$out" 2>"$err"
if cmp -s "$out" "$spike_dir/read/fixture-visible.ansi"; then
  ok "pane-read: ANSI output matches fixture-visible.ansi"
else
  bad "pane-read: ANSI output mismatch"
fi

"$herdr_bin" pane read w2:p1 --format text --json >"$out" 2>"$err"
if verify_shape "$spike_dir/read/fixture-api-visible-text.json" "$out" "read-text-json"; then
  ok "pane-read: text json matches fixture-api-visible-text.json shape"
else
  bad "pane-read: text json shape mismatch"
fi

"$herdr_bin" pane read w2:p1 --format ansi --json >"$out" 2>"$err"
if verify_shape "$spike_dir/read/fixture-api-visible-ansi.json" "$out" "read-ansi-json"; then
  ok "pane-read: ANSI json matches fixture-api-visible-ansi.json shape"
else
  bad "pane-read: ANSI json shape mismatch"
fi

# --- 6. Real local Unix domain socket server and layout.apply ---
# Re-seed so w2 workspace exists
"$control_bin" seed-spike

# Start foreground server detached in background
"$herdr_bin" --session nogging server &
server_pid=$!

# Wait for server to be ready
socket_path=""
for _ in {1..30}; do
  "$herdr_bin" session list --json >"$out" 2>/dev/null || true
  socket_path=$(python3 -c "import json; [print(s['socket_path']) for s in json.load(open('$out'))['sessions'] if s['name'] == 'nogging']" 2>/dev/null || true)
  if [[ -n "$socket_path" && -S "$socket_path" ]]; then
    break
  fi
  sleep 0.1
done

if [[ -n "$socket_path" && -S "$socket_path" ]]; then
  ok "server: started and bound Unix socket at $socket_path"
else
  bad "server: failed to bind Unix socket"
fi

# Verify socket permissions are 0600
sock_mode=$(stat -c "%a" "$socket_path")
if [[ "$sock_mode" == "600" ]]; then
  ok "server: socket has mode 0600"
else
  bad "server: socket mode is $sock_mode, expected 600"
fi

# Second server start prints error and exits 1
set +e
"$herdr_bin" --session nogging server >"$out" 2>"$err"
second_start_code=$?
set -e
if [[ $second_start_code -eq 1 ]] && grep -q "already running" "$err"; then
  ok "server: duplicate start prints 'already running' and exits 1"
else
  bad "server: duplicate start did not exit 1 with 'already running'"
fi

# Send layout.apply request over socket
req_json='{"id":"spike","method":"layout.apply","params":{"workspace_id":"w2","tab_label":"2","root":{"type":"pane","label":"sf-socket-pane","cwd":"/tmp","command":["bash","-c","printf line; sleep 300"],"env":{"HERDR_AGENT":"claude","SECRET_TOKEN":"super_secret_value"}}}}'
send_socket_request "$socket_path" "$req_json" >"$out" 2>"$err"

if verify_shape "$spike_dir/json/layout-apply.json" "$out" "layout-apply"; then
  ok "socket layout.apply: reply matches spike layout-apply.json shape"
else
  bad "socket layout.apply: reply shape mismatch"
fi

socket_pane_id=$(python3 -c "import json; print(json.load(open('$out'))['result']['layout']['root']['pane_id'])")

# Verify newly socket-created pane is visible via CLI
"$herdr_bin" pane list --workspace w2 >"$out" 2>"$err"
if grep -q "$socket_pane_id" "$out"; then
  ok "socket pane visible: pane list reports socket-created pane"
else
  bad "socket pane visible: pane list does not include $socket_pane_id"
fi

"$herdr_bin" pane get "$socket_pane_id" >"$out" 2>"$err"
if grep -q "sf-socket-pane" "$out"; then
  ok "socket pane visible: pane get reports label sf-socket-pane"
else
  bad "socket pane visible: pane get does not report sf-socket-pane"
fi

"$herdr_bin" pane process-info "$socket_pane_id" >"$out" 2>"$err"
if verify_shape "$spike_dir/json/pane-process-info.json" "$out" "socket-pane-process-info"; then
  ok "socket pane visible: process-info reports valid process info"
else
  bad "socket pane visible: process-info shape mismatch"
fi

# Verify calls.log records socket call with method and params, env redacted
if grep -q "socket layout.apply" "$HERDR_STUB_DIR/calls.log" && \
   grep -q '"SECRET_TOKEN": "\[redacted\]"' "$HERDR_STUB_DIR/calls.log" && \
   ! grep -q "super_secret_value" "$HERDR_STUB_DIR/calls.log"; then
  ok "socket calls.log: logged method layout.apply and redacted env SECRET_TOKEN"
else
  bad "socket calls.log: call log did not properly redact env values"
fi

# --- 7. Opt-in real pane process and pane close termination ---
"$control_bin" opt-in-real-process
real_req='{"id":"real-proc","method":"layout.apply","params":{"workspace_id":"w2","tab_label":"2","root":{"type":"pane","label":"real-child","cwd":"/tmp","command":["sleep","120"],"env":{}}}}'
send_socket_request "$socket_path" "$real_req" >"$out" 2>"$err"
real_pane_id=$(python3 -c "import json; print(json.load(open('$out'))['result']['layout']['root']['pane_id'])")

"$herdr_bin" pane process-info "$real_pane_id" >"$out" 2>"$err"
real_pid=$(python3 -c "import json; print(json.load(open('$out'))['result']['process_info']['shell_pid'])")

if kill -0 "$real_pid" 2>/dev/null; then
  ok "opt-in real process: spawned live child process (PID $real_pid)"
else
  bad "opt-in real process: child process $real_pid is not alive"
fi

# Close pane terminates real process
"$herdr_bin" pane close "$real_pane_id" >"$out" 2>"$err"
terminated=0
for _ in {1..20}; do
  if ! kill -0 "$real_pid" 2>/dev/null; then
    terminated=1
    break
  fi
  sleep 0.1
done

if [[ $terminated -eq 1 ]]; then
  ok "opt-in real process: pane close terminated process $real_pid"
else
  bad "opt-in real process: child process $real_pid was not terminated by pane close"
  kill -9 "$real_pid" 2>/dev/null || true
fi
"$control_bin" opt-out-real-process

# --- 8. Socket faults ---
# 8a. workspace_not_found error reply
bad_ws_req='{"id":"bad-ws","method":"layout.apply","params":{"workspace_id":"nonexistent_ws","root":{}}}'
send_socket_request "$socket_path" "$bad_ws_req" >"$out" 2>"$err"
if grep -q "workspace_not_found" "$out"; then
  ok "socket fault: nonexistent workspace returns workspace_not_found error"
else
  bad "socket fault: expected workspace_not_found error"
fi

# 8b. fault_drop_reply
touch "$HERDR_STUB_DIR/fault_drop_reply"
set +e
dropped_resp=$(send_socket_request "$socket_path" "$req_json" 2>&1)
set -e
if [[ -z "$dropped_resp" ]]; then
  ok "socket fault: fault_drop_reply closes connection without response"
else
  bad "socket fault: fault_drop_reply did not drop response (got: $dropped_resp)"
fi
rm -f "$HERDR_STUB_DIR/fault_drop_reply"

# 8c. unknown method returns error
unknown_req='{"id":"unkn","method":"unsupported.method","params":{}}'
send_socket_request "$socket_path" "$unknown_req" >"$out" 2>"$err"
if grep -q "unknown_method" "$out"; then
  ok "socket fault: unknown method returns error reply"
else
  bad "socket fault: expected unknown_method error"
fi

# Stop the server via server stop
"$herdr_bin" server stop >"$out" 2>"$err"
wait "$server_pid" 2>/dev/null || true
if ! kill -0 "$server_pid" 2>/dev/null; then
  ok "server stop: server process terminated cleanly"
else
  bad "server stop: server process did not terminate"
  kill -9 "$server_pid" 2>/dev/null || true
fi

# 8d. Connection refused when server is down
set +e
refused_out=$(send_socket_request "$socket_path" "$req_json" 2>&1)
refused_code=$?
set -e
if [[ $refused_code -ne 0 ]] || grep -qi "refused\|no such file" <<< "$refused_out"; then
  ok "socket fault: connection refused/fails when server not running"
else
  bad "socket fault: connection did not fail when server down"
fi

# --- 9. Path length limit (>= 108 bytes) ---
long_dir="$work/this_is_an_extremely_long_directory_path_designed_to_exceed_the_unix_socket_sun_path_limit_of_108_bytes_total_length"
mkdir -p "$long_dir"
echo "$long_dir/herdr.sock" >"$HERDR_STUB_DIR/socket_path"
set +e
"$herdr_bin" server >"$out" 2>"$err"
long_bind_code=$?
set -e
rm -f "$HERDR_STUB_DIR/socket_path"
if [[ $long_bind_code -ne 0 ]] && grep -qi "exceeds" "$err"; then
  ok "socket path limit: >= 108 byte socket path refused to bind"
else
  bad "socket path limit: failed to refuse socket path >= 108 bytes (code=$long_bind_code)"
fi

# --- 10. Socket permission and symlink/non-socket faults ---
# 10a. fault_socket_permissions
echo "0666" >"$HERDR_STUB_DIR/fault_socket_permissions"
"$herdr_bin" --session nogging server &
perm_pid=$!
for _ in {1..30}; do
  if [[ -S "$socket_path" ]]; then break; fi
  sleep 0.1
done
if [[ -S "$socket_path" ]]; then
  perm_mode=$(stat -c "%a" "$socket_path")
  if [[ "$perm_mode" == "666" ]]; then
    ok "socket fault: fault_socket_permissions sets mode 0666"
  else
    bad "socket fault: socket mode was $perm_mode, expected 666"
  fi
fi
"$herdr_bin" server stop >"$out" 2>"$err"
wait "$perm_pid" 2>/dev/null || true
rm -f "$HERDR_STUB_DIR/fault_socket_permissions"

# 10b. fault_socket_symlink
touch "$HERDR_STUB_DIR/fault_socket_symlink"
"$herdr_bin" --session nogging server &
sym_pid=$!
for _ in {1..30}; do
  if [[ -L "$socket_path" ]]; then break; fi
  sleep 0.1
done
if [[ -L "$socket_path" ]]; then
  ok "socket fault: fault_socket_symlink created a symlink socket"
else
  bad "socket fault: expected $socket_path to be a symlink"
fi
"$herdr_bin" server stop >"$out" 2>"$err"
wait "$sym_pid" 2>/dev/null || true
rm -f "$HERDR_STUB_DIR/fault_socket_symlink"

# 10c. fault_socket_non_socket
touch "$HERDR_STUB_DIR/fault_socket_non_socket"
"$herdr_bin" --session nogging server &
nonsock_pid=$!
for _ in {1..30}; do
  if [[ -f "$socket_path" && ! -S "$socket_path" ]]; then break; fi
  sleep 0.1
done
if [[ -f "$socket_path" && ! -S "$socket_path" ]]; then
  ok "socket fault: fault_socket_non_socket created regular file instead of socket"
else
  bad "socket fault: expected regular file at $socket_path"
fi
touch "$HERDR_STUB_DIR/server_stopped"
sleep 0.3
wait "$nonsock_pid" 2>/dev/null || true
rm -f "$HERDR_STUB_DIR/fault_socket_non_socket" "$HERDR_STUB_DIR/server_stopped"

# --- 11. Send text and keys (.after transition) ---
"$control_bin" seed-spike
"$herdr_bin" --session nogging server &
test_srv_pid=$!
sleep 0.3

# Create pane via socket layout.apply
send_socket_request "$socket_path" '{"id":"send-test","method":"layout.apply","params":{"workspace_id":"w2","tab_label":"2","root":{"type":"pane","label":"test-send","cwd":"/tmp","command":["bash"]}}}' >"$out" 2>"$err"
p_id=$(python3 -c "import json; print(json.load(open('$out'))['result']['layout']['root']['pane_id'])")

"$herdr_bin" pane send-text "$p_id" "hello from test" >"$out" 2>"$err"
printf 'after-enter-content\n' >"$HERDR_STUB_DIR/pane-$p_id.after"
"$herdr_bin" pane send-keys "$p_id" Enter >"$out" 2>"$err"
"$herdr_bin" pane read "$p_id" --format text >"$out" 2>"$err"
if grep -q "after-enter-content" "$out"; then
  ok "send-keys: Enter triggers .after file swap to current pane content"
else
  bad "send-keys: .after content was not applied upon Enter"
fi

# --- 12. Simulated server restart via control file ---
# Real process PIDs may fall in the fake's synthetic range on CI hosts.
# Check that every restart replaces identities regardless of the host PID.
if python3 - "$herdr_bin" <<'PY'
import runpy
import sys

simulate_restart = runpy.run_path(sys.argv[1])["simulate_restart"]
state = {"panes": {
    f"w1:p{index}": {"shell_pid": pid, "label": f"session-{index}", "agent": "codex"}
    for index, pid in enumerate((21000, 21442, 21999, 22000, 22442, 123456))
}}
for _ in range(3):
    previous = {pane["shell_pid"] for pane in state["panes"].values()}
    labels = {key: pane["label"] for key, pane in state["panes"].items()}
    simulate_restart(state)
    restored = [pane["shell_pid"] for pane in state["panes"].values()]
    assert previous.isdisjoint(restored), (previous, restored)
    assert len(set(restored)) == len(restored), restored
    assert {key: pane["label"] for key, pane in state["panes"].items()} == labels
    for pane in state["panes"].values():
        assert pane["foreground_process_group_id"] == pane["shell_pid"]
        assert pane["foreground_processes"][0]["pid"] == pane["shell_pid"]
        assert pane["agent_status"] == "unknown" and "agent" not in pane
PY
then
  ok "restart: replacement PIDs are distinct from all old PIDs across repeated restarts"
else
  bad "restart: replacement process identity collides"
fi

"$herdr_bin" pane process-info "$p_id" >"$out" 2>"$err"
pid_before=$(python3 -c "import json; print(json.load(open('$out'))['result']['process_info']['shell_pid'])")

# Trigger restart via control file
"$control_bin" simulate-restart
"$herdr_bin" pane process-info "$p_id" >"$out" 2>"$err"
pid_after=$(python3 -c "import json; print(json.load(open('$out'))['result']['process_info']['shell_pid'])")

if [[ "$pid_before" != "$pid_after" ]]; then
  ok "restart: server restart allocates new shell_pid (before: $pid_before, after: $pid_after)"
else
  bad "restart: shell_pid unchanged across restart"
fi

# Label and pane_id persisted
"$herdr_bin" pane get "$p_id" >"$out" 2>"$err"
lbl=$(python3 -c "import json; print(json.load(open('$out'))['result']['pane']['label'])")
if [[ "$lbl" == "test-send" ]]; then
  ok "restart: pane_id and label persist across restart"
else
  bad "restart: label lost across restart (got $lbl)"
fi

# --- 13. Error shapes ---
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

"$herdr_bin" status >"$out" 2>"$err"
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

# --- 14. Injectable failures ---
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
if "$herdr_bin" pane list >"$out" 2>"$err"; then
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

# --- 15. Call log ---
if [[ -f "$HERDR_STUB_DIR/calls.log" ]]; then
  if grep -q "pane send-text" "$HERDR_STUB_DIR/calls.log" && \
     grep -q "pane send-keys" "$HERDR_STUB_DIR/calls.log" && \
     grep -q "pane read" "$HERDR_STUB_DIR/calls.log" && \
     grep -q "socket layout.apply" "$HERDR_STUB_DIR/calls.log"; then
    ok "calls.log: records invocations with expected command lines and socket calls"
  else
    bad "calls.log: missing expected invocations"
  fi
else
  bad "calls.log: file not created"
fi

# Cleanup server
"$herdr_bin" server stop >"$out" 2>"$err"
wait "$test_srv_pid" 2>/dev/null || true

echo
if [[ $fail -ne 0 ]]; then
  echo "FAIL - scripts/herdr-stub.test.sh"
  exit 1
fi
echo "PASS - scripts/herdr-stub.test.sh"
exit 0
