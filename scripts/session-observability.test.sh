#!/usr/bin/env bash
# Regression checks for the session-observability capability
# (openspec/changes/session-observability).
#
# TASK-SOB-001: the `Adapter` data shape and the `claude` / `codex` pattern
# tables, classified via fixture pane captures — no live agent required.
# Covers the `Auto-update failed` false-positive regression explicitly.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

classify() {
  # classify <adapter> <pane-text-stdin>
  PANE_TEXT="$(cat)" python3 - "$nogg" "$1" <<'PY'
import os, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_sob_classify", sys.argv[1]).load_module()
adapter = m.ADAPTERS[sys.argv[2]]
pane = os.environ["PANE_TEXT"]
print(m.classify(pane, adapter))
PY
}

# ===========================================================================
# claude adapter fixtures
# ===========================================================================
got=$(printf 'some output above\nesc to interrupt\n' | classify claude)
[[ "$got" == "working" ]] && ok "claude: 'esc to interrupt' classifies working" \
  || bad "claude: expected working, got $got"

got=$(printf '2 shells still running\n' | classify claude)
[[ "$got" == "waiting_background" ]] && ok "claude: background shells classify waiting_background" \
  || bad "claude: expected waiting_background, got $got"

got=$(printf 'Do you want to proceed?\n❯ 1. Yes\n' | classify claude)
[[ "$got" == "needs_input" ]] && ok "claude: permission prompt classifies needs_input" \
  || bad "claude: expected needs_input, got $got"

got=$(printf 'Claude usage limit reached. Your limit will reset at 3:30pm.\n' | classify claude)
[[ "$got" == "limit" ]] && ok "claude: usage-limit banner classifies limit" \
  || bad "claude: expected limit, got $got"

got=$(printf 'some prior output\n❯ \n' | classify claude)
[[ "$got" == "idle" ]] && ok "claude: a bare prompt classifies idle" \
  || bad "claude: expected idle, got $got"

got=$(printf 'nothing recognizable here\n' | classify claude)
[[ "$got" == "unknown" ]] && ok "claude: unrecognized pane text classifies unknown" \
  || bad "claude: expected unknown, got $got"

# --- the regression case this change exists to fix -----------------------
got=$(printf 'Auto-update failed: no write permission to npm prefix\n3 shells still running\n' | classify claude)
[[ "$got" == "waiting_background" ]] \
  && ok "claude: Auto-update failed banner + background shells is waiting_background, not unknown" \
  || bad "claude: expected waiting_background (Auto-update regression), got $got"

got=$(printf 'Auto-update failed: no write permission to npm prefix\n' | classify claude)
[[ "$got" == "unknown" ]] \
  && ok "claude: Auto-update failed banner alone (nothing else happening) is unknown, not a false 'attention' state" \
  || bad "claude: expected unknown with only the ignored banner present, got $got"

# ===========================================================================
# codex adapter fixtures
# ===========================================================================
got=$(printf 'Working (12s · esc to interrupt)\n' | classify codex)
[[ "$got" == "working" ]] && ok "codex: 'Working (' classifies working" \
  || bad "codex: expected working, got $got"

got=$(printf '> Ask Codex to do anything\n' | classify codex)
[[ "$got" == "idle" ]] && ok "codex: idle prompt classifies idle" \
  || bad "codex: expected idle, got $got"

got=$(printf '[Pasted Content]\n> Ask Codex to do anything\n' | classify codex)
[[ "$got" == "needs_input" ]] \
  && ok "codex: undelivered_input (Pasted Content) outranks an idle-looking pane" \
  || bad "codex: expected needs_input, got $got"

if [[ $fail -ne 0 ]]; then
  echo "session-observability: FAILED" >&2
  exit 1
fi
echo "session-observability: all checks passed"
