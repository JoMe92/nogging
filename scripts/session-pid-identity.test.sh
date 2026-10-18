#!/usr/bin/env bash
# TASK-LCD-006: launch a real planning session through the CLI and model a
# foreign tmux PID namespace by hiding the reported pane PID from launcher
# /proc reads. The runtime stub attempts plan-begin in the launched session.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/lib/test-env.sh"
source "$here/lib/test-agents.sh"
while IFS= read -r name; do
  case "$name" in NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_TMPDIR|TMUX_STUB_DIR|TMUX_STATEFUL_STUB) unset "$name" ;; esac
done < <(compgen -e)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/consumer"
mkdir -p "$root/scripts/lib" "$root/.nogging/state/sessions" "$root/.nogging/locks" "$root/.nogging/launch-profiles" "$root/.nogging/launch-prompts" "$root/scripts" "$work/bin" "$work/agents" "$work/tmux"
cp -R "$here/lib/." "$root/scripts/lib/"
cp "$here/nogg" "$here/session-launch" "$here/session-log-writer" "$here/openspec-sandbox" "$here/nogg_usage.py" "$root/scripts/"
cp -R "$here/../.nogging/launch-profiles/." "$root/.nogging/launch-profiles/"
cp -R "$here/../.nogging/launch-prompts/." "$root/.nogging/launch-prompts/"
cp "$here/../.nogging/config.json" "$root/.nogging/config.json"
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
import json, os, subprocess, sys
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
    proc = subprocess.Popen(argv, cwd=cwd, env=os.environ.copy(), stdin=subprocess.DEVNULL,
                            stdout=open(os.path.join(state, 'pane.out'), 'w'),
                            stderr=subprocess.STDOUT, start_new_session=True)
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
"$NOGGING_ROOT/scripts/nogg" plan-begin >"$NOGG_TEST_PLAN_OUT" 2>&1
exit $?
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux" "$work/agents/claude"
export NOGGING_ROOT="$root" TMUX_STUB_DIR="$work/tmux" TMUX_STATEFUL_STUB=1 NOGG_TEST_PLAN_OUT="$work/plan.out"
export PATH="$work/agents:$work/bin:$PATH"
cat > "$work/drive.py" <<'PY'
import importlib.machinery, importlib.util, json, os, sys, time
loader = importlib.machinery.SourceFileLoader('nogg_identity_test', sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
m = importlib.util.module_from_spec(spec); sys.modules[loader.name] = m; loader.exec_module(m)
backend = m.session_backend_module()
real_start, real_ns = m.process_start, m.pid_namespace
reported = [None]
# Resolve the actual backend PID, then make only launcher's reads for that PID
# fail. The tmux fake and pane process still run in the ordinary host namespace.
original_pid = backend._tmux
class HiddenReads:
    def __call__(self, pid):
        if reported[0] is None: reported[0] = pid
        return None if pid == reported[0] else real_start(pid)
def hidden_ns(pid='self'):
    if reported[0] is not None and str(pid) == str(reported[0]): return None
    return real_ns(pid)
m.process_start = HiddenReads()
m.pid_namespace = hidden_ns
backend.process_start = m.process_start
backend.pid_namespace = m.pid_namespace
clock = [0.0]
m._settle_clock = lambda: clock[0]
m._settle_sleep = lambda seconds: clock.__setitem__(0, clock[0] + seconds)
sys.argv = ['nogg', 'session', 'launch', '--role', 'planning', '--planning-id', 'identity-probe', '--description', 'pid-identity-probe', '--profile', 'trusted']
try:
    m.main()
except Exception as exc:
    print(f'nogg: {exc}', file=sys.stderr); sys.exit(1)
PY
if ! python3 "$work/drive.py" "$root/scripts/nogg" >"$work/launch.out" 2>&1; then cat "$work/launch.out"; exit 1; fi
sleep 0.2
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
