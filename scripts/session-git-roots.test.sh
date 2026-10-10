#!/usr/bin/env bash
# SPEC-9085: launch arguments must reopen actual Git metadata, including linked
# worktrees, and preserve SSH overrides inside the outer filesystem namespace.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
root="$work/repo with \"quotes\""
mkdir -p "$root/scripts" "$work/bin" "$work/home with spaces/.ssh"
cp "$here/nogg" "$here/session-launch" "$root/scripts/"
mkdir -p "$root/.nogging"
printf '{}\n' > "$root/.nogging/config.json"
git init -q "$root"
git -C "$root" -c user.name=Test -c user.email=test@example.com commit -qm initial --allow-empty
git -C "$root" worktree add -qb linked "$work/linked"
: > "$work/home with spaces/.ssh/config"
cat > "$work/bin/codex" <<'STUB'
#!/usr/bin/env python3
import json, os, sys
with open(os.environ['LAUNCH_RESULT'], 'w') as f:
    json.dump({'argv': sys.argv[1:], 'ssh': os.environ.get('GIT_SSH_COMMAND')}, f)
STUB
chmod +x "$work/bin/codex"
export PATH="$work/bin:$PATH" LAUNCH_RESULT="$work/result.json"
for cwd in "$root" "$work/linked"; do
  env -u GIT_SSH_COMMAND HOME="$work/home with spaces" "$root/scripts/session-launch" \
    --agent codex --cwd "$cwd" --sandbox workspace-write --network off >/dev/null
  python3 - "$root" "$cwd" "$LAUNCH_RESULT" <<'PY'
import json, subprocess, sys, tomllib, shlex
root, cwd, result = sys.argv[1:]
data = json.load(open(result))
arg = next(a for a in data['argv'] if a.startswith('sandbox_workspace_write.writable_roots='))
roots = tomllib.loads(arg)['sandbox_workspace_write']['writable_roots']
def git(path, *args):
    return subprocess.check_output(['git', '-C', path, 'rev-parse', *args], text=True).strip()
expected = list(dict.fromkeys([git(root, '--path-format=absolute', '--git-common-dir'), git(cwd, '--absolute-git-dir')]))
assert roots == expected, (roots, expected)
assert shlex.split(data['ssh'])[0:2] == ['ssh', '-F']
assert shlex.split(data['ssh'])[2].endswith('/home with spaces/.ssh/config')
assert 'sandbox_workspace_write.network_access=false' in data['argv']
PY
  echo "ok - writable Git roots for $cwd"
done
GIT_SSH_COMMAND='operator-ssh --custom' "$root/scripts/session-launch" --agent codex --cwd "$root" >/dev/null
python3 - "$LAUNCH_RESULT" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['ssh'] == 'operator-ssh --custom'
PY
echo 'ok - explicit SSH command preserved'
mkdir -p "$work/home with spaces/.agy-state"
for bad in /etc "$work/home with spaces" "$work/missing" "relative/dir"; do
  if HOME="$work/home with spaces" NOGG_CODEX_EXTRA_WRITABLE_ROOTS="$bad" \
      "$root/scripts/session-launch" --agent codex --cwd "$root" >/dev/null 2>&1; then
    echo "FAIL: extra root accepted: $bad" >&2; exit 1
  fi
done
echo 'ok - extra roots outside HOME, HOME itself, missing and relative are refused'
