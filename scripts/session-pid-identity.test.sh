#!/usr/bin/env bash
# TASK-LCD-006: launch a real planning session through the CLI and model a
# foreign tmux PID namespace by hiding the reported pane PID from launcher
# /proc reads. The runtime stub attempts plan-begin in the launched session.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib/test-env.sh"
source "$here/lib/test-agents.sh"
while IFS= read -r name; do
  case "$name" in NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_TMPDIR|TMUX_STUB_DIR|TMUX_STATEFUL_STUB) unset "$name" ;; esac
done < <(compgen -e)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stub_agent_binaries "$work/agents"
root="$work/consumer"
mkdir -p "$root/scripts/lib" "$root/.nogging/state/sessions" "$root/.nogging/locks" "$root/.nogging/launch-profiles" "$root/.nogging/launch-prompts" "$root/scripts" "$work/bin" "$work/agents" "$work/tmux"
cp -R "$here/lib/." "$root/scripts/lib/"
cp "$here/nogg" "$here/session-launch" "$here/session-log-writer" "$here/openspec-sandbox" "$here/nogg_usage.py" "$root/scripts/"
cp -R "$here/../.nogging/launch-profiles/." "$root/.nogging/launch-profiles/"
cp -R "$here/../.nogging/launch-prompts/." "$root/.nogging/launch-prompts/"
copy_host_config "$here/../.nogging/config.json" "$root/.nogging/config.json"
git -C "$root" init -q
git init --bare -q "$work/origin.git"
git -C "$root" config user.email test@example.invalid
git -C "$root" config user.name Test
git -C "$root" add .
git -C "$root" commit -qm seed
git -C "$root" branch -M develop
git -C "$root" remote add origin "$work/origin.git"
git -C "$root" push -q -u origin develop
cat > "$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == show ]]; then printf '[{"id":"%s","title":"stub"}]\n' "${2:-}"; exit 0; fi
if [[ "${1:-}" == dep && "${2:-}" == list ]]; then echo '[]'; exit 0; fi
exit 0
STUB
cat > "$work/bin/tmux" <<'STUB'
#!/usr/bin/env python3
import json, os, subprocess, sys, time
args = sys.argv[1:]
if args[:1] == ['-L']: args = args[2:]
if args[:1] == ['-N']: args = args[1:]
cmd, args = args[0], args[1:]
state = os.environ['TMUX_STUB_DIR']
path = os.path.join(state, 'session.json')
def read():
    try: return json.load(open(path))
    except (OSError, ValueError): return {}
def write(value):
    with open(path, 'w') as f: json.dump(value, f)
if cmd == 'new-session':
    cwd = args[args.index('-c') + 1]
    argv = args[args.index('--') + 1:]
    child_env = os.environ.copy()
    for i, value in enumerate(args[:-1]):
        if value == '-e' and '=' in args[i + 1]:
            key, item = args[i + 1].split('=', 1); child_env[key] = item
    if os.environ.get('NOGG_TEST_NO_RECEIPT') == '1':
        child_env.pop('NOGG_PID_RECEIPT', None)
    proc = subprocess.Popen(argv, cwd=cwd, env=child_env, stdin=subprocess.DEVNULL,
                            stdout=open(os.path.join(state, 'pane.out'), 'w'),
                            stderr=subprocess.STDOUT, start_new_session=True)
    receipt = child_env.get('NOGG_PID_RECEIPT')
    deadline = time.monotonic() + 2
    while receipt and not os.path.exists(receipt) and time.monotonic() < deadline:
        time.sleep(0.01)
    if receipt and os.environ.get('NOGG_TEST_MISMATCH_RECEIPT') == '1' and os.path.exists(receipt):
        identity = json.load(open(receipt)); identity['pid'] += 1
        json.dump(identity, open(receipt, 'w'))
    write({'pid': proc.pid, 'name': args[args.index('-s') + 1]})
elif cmd == 'display-message':
    print(read().get('pid', ''))
elif cmd == 'has-session':
    if not read(): sys.exit(1)
elif cmd == 'list-sessions':
    current = read()
    if not current: sys.exit(1)
    print(current['name'])
elif cmd == 'kill-session':
    current = read()
    if current:
        try: os.kill(current['pid'], 15)
        except ProcessLookupError: pass
        os.unlink(path)
elif cmd == 'pipe-pane':
    pass
else:
    pass
STUB
cat > "$work/agents/claude" <<'STUB'
#!/usr/bin/env bash
deadline=$((SECONDS + 5))
while [[ ! -e "$NOGG_TEST_RELEASE" && $SECONDS -lt $deadline ]]; do sleep 0.01; done
[[ -e "$NOGG_TEST_RELEASE" ]] || exit 9
unset NOGGING_ROOT
"$PWD/scripts/nogg" plan-begin >"$NOGG_TEST_PLAN_OUT" 2>&1
rc=$?
"$PWD/scripts/nogg" plan-end >>"$NOGG_TEST_PLAN_OUT" 2>&1 || rc=$?
exit "$rc"
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux" "$work/agents/claude"
export NOGGING_ROOT="$root" TMUX_STUB_DIR="$work/tmux" TMUX_STATEFUL_STUB=1 NOGG_TEST_PLAN_OUT="$work/plan.out" NOGG_TEST_RELEASE="$work/release"
export PATH="$work/agents:$work/bin:$PATH"
cat > "$work/drive.py" <<'PY'
import importlib.machinery, importlib.util, json, os, sys, time
loader = importlib.machinery.SourceFileLoader('nogg_identity_test', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); sys.modules[loader.name] = m; loader.exec_module(m)
assert not m._is_legacy_mock(), 'the real session launch path must run'
backend = m.session_backend_module()
from session_backend_tmux import TmuxBackend
real_start, real_ns, real_pid = m.process_start, m.pid_namespace, TmuxBackend.pid
reported = [None]
# Capture the backend-reported pane PID, then optionally hide only that PID
# from launcher's /proc reads. The wrapper still reads its own namespace.
def capture_pid(self, ref):
    reported[0] = real_pid(self, ref)
    return reported[0]
class HiddenReads:
    def __call__(self, pid):
        return None if reported[0] is not None and int(pid) == reported[0] else real_start(pid)
def hidden_ns(pid='self'):
    if reported[0] is not None and str(pid) == str(reported[0]): return None
    return real_ns(pid)
if os.environ.get('NOGG_TEST_HIDE_IDENTITY', '1') == '1':
    TmuxBackend.pid = capture_pid
    m.process_start = HiddenReads()
    m.pid_namespace = hidden_ns
clock = [0.0]
m._settle_clock = lambda: clock[0]
m._settle_sleep = lambda seconds: clock.__setitem__(0, clock[0] + seconds)
planning_id = os.environ.get('NOGG_TEST_PLAN_ID', 'identity-probe')
sys.argv = ['nogg', 'session', 'launch', '--role', 'planning', '--planning-id', planning_id, '--description', 'pid-identity-probe', '--profile', 'trusted']
try:
    m.main()
except Exception as exc:
    print(f'nogg: {exc}', file=sys.stderr); sys.exit(1)
PY
if ! python3 "$work/drive.py" "$root/scripts/nogg" >"$work/launch.out" 2>&1; then cat "$work/launch.out"; exit 1; fi
touch "$NOGG_TEST_RELEASE"
for _ in {1..100}; do grep -q 'planning session lock acquired' "$NOGG_TEST_PLAN_OUT" 2>/dev/null && break; sleep 0.01; done
record=$(find "$root/.nogging/state/sessions" -maxdepth 1 -name '*.json' ! -name '*.settings.json' -print -quit)
python3 - "$record" "$NOGG_TEST_PLAN_OUT" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
plan = open(sys.argv[2]).read()
assert record['session_pid'] is not None, record
assert record['session_pid_start'], record
assert record['session_pid_ns'], record
assert record.get('session_pid_identity_source') == 'wrapper', record
assert 'planning session lock acquired' in plan, plan
print('planning PID identity: hidden launcher /proc reads recovered from wrapper receipt')
PY
session_name=$(python3 - "$record" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['name'])
PY
)
"$root/scripts/nogg" session stop "$session_name" >/dev/null 2>&1 || true

# The ordinary same-namespace path keeps the launcher's identity unchanged.
rm -f "$NOGG_TEST_RELEASE" "$NOGG_TEST_PLAN_OUT"
export NOGG_TEST_PLAN_ID=identity-baseline NOGG_TEST_HIDE_IDENTITY=0
python3 "$work/drive.py" "$root/scripts/nogg" >"$work/launch.out" 2>&1 || { cat "$work/launch.out"; exit 1; }
touch "$NOGG_TEST_RELEASE"
for _ in {1..100}; do grep -q 'planning session lock acquired' "$NOGG_TEST_PLAN_OUT" 2>/dev/null && break; sleep 0.01; done
record=$(find "$root/.nogging/state/sessions" -maxdepth 1 -name '*identity-baseline*.json' ! -name '*.settings.json' -print -quit)
python3 - "$record" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
assert record['session_pid_start'] and record['session_pid_ns'], record
assert record.get('session_pid_identity_source') is None, record
print('planning PID identity: visible launcher /proc identity preserved')
PY
session_name=$(python3 - "$record" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['name'])
PY
)
"$root/scripts/nogg" session stop "$session_name" >/dev/null 2>&1 || true

# Without a receipt, or with one whose PID differs from tmux's pane PID, a
# planning launch is refused and its created session is cleaned up.
for mode in no-receipt mismatch-receipt; do
  rm -f "$NOGG_TEST_RELEASE" "$NOGG_TEST_PLAN_OUT" "$TMUX_STUB_DIR/session.json"
  export NOGG_TEST_NO_RECEIPT=0 NOGG_TEST_MISMATCH_RECEIPT=0 NOGG_TEST_PLAN_ID="identity-probe-$mode" NOGG_TEST_HIDE_IDENTITY=1
  if [[ "$mode" == no-receipt ]]; then export NOGG_TEST_NO_RECEIPT=1; else export NOGG_TEST_MISMATCH_RECEIPT=1; fi
  if python3 "$work/drive.py" "$root/scripts/nogg" >"$work/launch.out" 2>&1; then
    echo "FAIL: planning launch accepted $mode" >&2; exit 1
  fi
  grep -qF 'launch from an unsandboxed shell' "$work/launch.out" || { cat "$work/launch.out"; exit 1; }
  [[ ! -e "$TMUX_STUB_DIR/session.json" ]]
  ! grep -q 'planning session lock acquired' "$NOGG_TEST_PLAN_OUT" 2>/dev/null
  failed=$(find "$root/.nogging/state/sessions" -maxdepth 1 -name '*.json' ! -name '*.settings.json' -print | sort | tail -1)
  python3 - "$failed" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
assert record['state'] == 'failed', record
assert 'cleanup succeeded' in record['exit_reason'], record
assert record.get('session_pid_start') is None and record.get('session_pid_ns') is None, record
PY
  echo "planning PID identity: $mode refused and tmux session cleaned up"
done
