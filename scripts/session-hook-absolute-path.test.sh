#!/usr/bin/env bash
# Regression suite for TASK-LHF-003: Claude Stop/Notification hook absolute paths.
# Decision 4 (#204):
# - Generate settings via real merge for a root containing spaces.
# - Assert Stop and Notification commands are absolute and quoted.
# - Execute Stop command via sh -c from a subdirectory of a scratch repo with a stub session
#   and assert turn_end is appended to the session's events.
# - Assert no relative scripts/ command remains in the generated settings.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
nogg="$repo_root/scripts/nogg"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

export HOME="$work/home"
mkdir -p "$HOME"

# Root containing a space
space_root="$work/space repo root"
mkdir -p "$space_root/.nogging/state" "$space_root/scripts"
copy_host_config "$repo_root/.nogging/config.json" "$space_root/.nogging/config.json"
git init -q "$space_root"
cp "$repo_root/scripts/nogg" "$space_root/scripts/"
cp -r "$repo_root/scripts/lib" "$space_root/scripts/"
chmod +x "$space_root/scripts/nogg"

# 1. Test merge_observability_hooks with NOGGING_ROOT set to space_root
settings_json=$(NOGGING_ROOT="$space_root" python3 - "$space_root/scripts/nogg" <<'PY'
import json, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg_test", sys.argv[1]).load_module()
settings = {
    "permissions": {"defaultMode": "default"},
    "hooks": {
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo guard"}]}]
    }
}
res = m.merge_observability_hooks(settings)
print(json.dumps(res))
PY
)

# Parse output settings
eval_res=$(python3 - "$settings_json" "$space_root" <<'PY'
import json, os, shlex, sys

d = json.loads(sys.argv[1])
root = sys.argv[2]
expected_stop = f"{shlex.quote(os.path.join(root, 'scripts/nogg'))} session emit turn_end --guard"
expected_notif = f"{shlex.quote(os.path.join(root, 'scripts/nogg'))} session emit needs_input"

hooks = d.get("hooks", {})
stop = hooks.get("Stop", [])
notif = hooks.get("Notification", [])

if not stop or stop[0]["hooks"][0]["command"] != expected_stop:
    sys.exit(f"Stop command mismatch: expected {expected_stop!r}, got {stop}")
if not notif or notif[0]["hooks"][0]["command"] != expected_notif:
    sys.exit(f"Notification command mismatch: expected {expected_notif!r}, got {notif}")

# Check that commands are absolute and quoted
stop_cmd = stop[0]["hooks"][0]["command"]
if not stop_cmd.startswith("'") or not stop_cmd.startswith(f"'{root}"):
    sys.exit(f"Stop command not properly quoted or absolute: {stop_cmd}")

# Check no relative scripts/ command exists anywhere in hooks
for event, entries in hooks.items():
    for entry in entries:
        for h in entry.get("hooks", []):
            cmd = h.get("command", "")
            if cmd.startswith("scripts/") or " scripts/" in cmd:
                sys.exit(f"Relative scripts/ found in hook command for {event}: {cmd}")

print("OK")
PY
)

[[ "$eval_res" == "OK" ]] \
  && ok "merge_observability_hooks: Stop and Notification commands are absolute, shell-quoted, and no relative scripts/ remains" \
  || bad "merge_observability_hooks check failed: $eval_res"

# 2. Test firing the Stop command from a subdirectory
sub="$space_root/some/deep/subdir"
mkdir -p "$sub"

# Setup session state in space_root so session emit works
session_name="test-sess-obs"
mkdir -p "$space_root/.nogging/state/sessions"
events_file="$space_root/.nogging/state/sessions/$session_name.events.jsonl"

# Extract the stop command from settings_json
stop_command=$(python3 -c "import json, sys; print(json.loads('''$settings_json''')['hooks']['Stop'][0]['hooks'][0]['command'])")

# Run the Stop command via sh -c inside $sub with NOGG_SESSION_NAME and NOGGING_ROOT set
(
  cd "$sub"
  export NOGG_SESSION_NAME="$session_name"
  export NOGGING_ROOT="$space_root"
  sh -c "$stop_command"
)

[[ -f "$events_file" ]] \
  && ok "Stop hook execution: events file created from subdirectory" \
  || bad "Stop hook execution: events file $events_file not created"

if grep -qF '"event": "turn_end"' "$events_file" && grep -qF "\"session\": \"$session_name\"" "$events_file"; then
  ok "Stop hook execution: turn_end recorded correctly when fired from subdirectory"
else
  bad "Stop hook execution: event not recorded properly in $events_file: $(cat "$events_file" 2>/dev/null || true)"
fi

if [[ $fail -ne 0 ]]; then
  echo "session-hook-absolute-path: checks failed" >&2
  exit 1
fi
echo "session-hook-absolute-path: all checks passed"
