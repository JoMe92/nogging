#!/usr/bin/env bash
# Focused checks for TASK-LHF-001 (#184): only blocking dependency edges
# (dependency_type `blocks` or absent, status not closed) refuse a launch.
# Drives unmet_dependencies() and the PreToolUse launch guard with the same
# fixtures against a stubbed `bd`.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=lib/test-env.sh
source "$root/scripts/lib/test-env.sh"
unset -v HERDR_ENV TMUX TMUX_TMPDIR 2>/dev/null || true
for v in "${!HERDR_@}"; do unset -v "$v"; done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
scratch="$work/repo"
mkdir -p "$scratch/.nogging" "$work/bin"
printf '{"beads_command": "bd"}\n' > "$scratch/.nogging/config.json"
cat > "$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "dep" && "$2" == "list" ]]; then
  printf '%s\n' "${BD_DEP_LIST_JSON:-[]}"
  exit 0
fi
echo "unexpected bd call: $*" >&2
exit 1
STUB
chmod +x "$work/bin/bd"
export PATH="$work/bin:$PATH" CLAUDE_PROJECT_DIR="$scratch"

fail=0
EPIC='{"id":"SPEC-epic","status":"open","dependency_type":"parent-child"}'
BLOCK='{"id":"SPEC-blocker","status":"open","dependency_type":"blocks"}'
CLOSED='{"id":"SPEC-done","status":"closed","dependency_type":"blocks"}'
TYPELESS='{"id":"SPEC-legacy","status":"open"}'

py_names() { # prints the comma-joined unmet_dependencies() result
  NOGGING_ROOT="$scratch" python3 - "$root/scripts/nogg" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("nogg_under_test", sys.argv[1]).load_module()
print(",".join(m.unmet_dependencies("SPEC-x")))
PY
}
hook_out() { # prints "<rc>|<stderr>" of the launch guard
  local rc=0 out
  out=$(printf '{"tool_input":{"command":"scripts/nogg session launch --role lead --bead SPEC-x"}}' \
    | "$root/scripts/hooks/pre-tool-use-lead-launch-guard" 2>&1) || rc=$?
  printf '%s|%s' "$rc" "$out"
}

# check <desc> <json> <expected comma-joined blockers, "" for launchable>
check() {
  local desc="$1" json="$2" want="$3" got hook rc
  export BD_DEP_LIST_JSON="$json"
  got=$(py_names)
  hook=$(hook_out); rc=${hook%%|*}
  if [[ "$got" != "$want" ]]; then
    echo "FAIL - $desc: unmet_dependencies gave '$got', want '$want'"; fail=1; return
  fi
  if [[ -z "$want" ]]; then
    [[ "$rc" == 0 ]] || { echo "FAIL - $desc: hook refused (rc=$rc)"; fail=1; return; }
  else
    [[ "$rc" == 2 && "$hook" == *"$want"* ]] || { echo "FAIL - $desc: hook rc=$rc output: $hook"; fail=1; return; }
    if [[ "$hook" == *SPEC-epic* ]]; then echo "FAIL - $desc: hook named the epic"; fail=1; return; fi
  fi
  echo "ok   - $desc"
}

check "open epic parent alone launches" "[$EPIC]" ""
check "open blocks blocker refuses, naming only the blocker" "[$BLOCK]" "SPEC-blocker"
check "closed blocks blocker launches" "[$CLOSED]" ""
check "epic parent plus open blocker names only the blocker" "[$EPIC,$BLOCK]" "SPEC-blocker"
check "typeless entry still blocks" "[$TYPELESS]" "SPEC-legacy"

exit "$fail"
