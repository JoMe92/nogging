#!/usr/bin/env bash
# TASK-SWK-004 (openspec/changes/session-wake): the dispatcher. The Decision 7 table
# is pure decide() cases in session_dispatch_test.py; this file covers the config
# refusal and one real pass. Offline: stub agents on a private socket, stub gh, stub bd.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-agents.sh"; use_agent_stubs

while IFS= read -r inherited; do
  case "$inherited" in
    NOGG_*|NOGGING_*|HERDR_*|TMUX|TMUX_*|GIT_*) unset "$inherited" ;;
  esac
done < <(compgen -e)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
nogg="$here/nogg"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
expect() { # expect <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok "$1"; else bad "$1 (expected: $2, got: $3)"; fi
}

# --- the pure decision (source-only; an installed consumer skips) ---------------
if [[ -f "$here/lib/session_dispatch_test.py" ]]; then
  python3 "$here/lib/session_dispatch_test.py" >"$work/unit.out" 2>&1 && ok "session_dispatch_test.py" \
    || { bad "session_dispatch_test.py"; cat "$work/unit.out"; }
else
  ok "session_dispatch_test.py skipped (installed consumer copy)"
fi

# --- config refusal through doctor ----------------------------------------------
diagnose() { # diagnose <json>: the config diagnostics for that config
  python3 - "$nogg" "$1" <<'PY'
import json, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_swk004", sys.argv[1]).load_module()
m.CFG = dict(m.CFG, **json.loads(sys.argv[2]))
print("; ".join(line for line, _ in m.session_dispatch_diagnostics()))
PY
}
expect "config: a default install has no diagnostics" "" "$(diagnose '{}')"
expect "config: a typo is refused, naming the key" \
  "session dispatch config: session_dispatch: unknown key 'max_nudge'" "$(diagnose '{"session_dispatch": {"max_nudge": 2}}')"
expect "config: orchestrator_context refuses an unknown key too" \
  "session dispatch config: orchestrator_context: unknown key 'window'" "$(diagnose '{"orchestrator_context": {"window": 1}}')"
python3 - "$repo_root" "$here/lib" <<'PY' && ok "config: the template block is valid, disabled and retires nothing" || bad "config: template block"
import json, os, sys
sys.path.insert(0, sys.argv[2])
sys.dont_write_bytecode = True
import session_dispatch as d
path = os.path.join(sys.argv[1], "templates/nogging-config.json")
if os.path.exists(path):
    template = json.load(open(path))
    assert d.config_errors(template) == [], d.config_errors(template)
    assert template["session_dispatch"]["enabled"] is False
    assert template["session_dispatch"]["retire_merged"] is False
PY

# --- shipped files ----------------------------------------------------------
# The installed consumer copy has no bin/ or package.json; check only where present.
for shipped in bin/lib/manifest.js package.json; do
  if [[ -f "$repo_root/$shipped" ]]; then
    grep -q "scripts/lib/session_dispatch.py" "$repo_root/$shipped" && ok "$shipped ships session_dispatch.py" || bad "$shipped misses session_dispatch.py"
  fi
done

[[ $fail -eq 0 ]] || { echo "session-dispatch: checks failed" >&2; exit 1; }
echo "session-dispatch: ok"
