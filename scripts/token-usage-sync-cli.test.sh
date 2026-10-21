#!/usr/bin/env bash
# `nogg token-usage sync` through the real CLI (TASK-TUC-006):
#   - authority is proven by process ancestry: a restricted session is refused
#     sync and import with or without its session environment; a session
#     name that ancestry does not confirm (spoofed, unknown, or a restricted
#     process naming a trusted session) fails closed; trusted and operator
#     callers pass;
#   - collect and report never contact the remote (an unreachable remote does
#     not affect them, and no sync status appears);
#   - an operator sync pushes to a file:// remote; report, status and doctor
#     show synchronization freshness without exposing remote credentials.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
err=$(mktemp)   # JSON assertions read stdout only; stderr is kept for failures
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -f "$out" "$err"; rm -rf "$work"' EXIT
command -v dolt >/dev/null 2>&1 || { echo "ok   - dolt not installed; sync CLI checks skipped"; exit 0; }

mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "show" ]]; then printf '[{"id":"%s","title":"stub"}]\n' "${2:-}"; exit 0; fi
if [[ "${1:-}" == "dep" ]]; then echo '[]'; exit 0; fi
exit 1
STUB
cat >"$work/bin/tmux" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$work/bin/bd" "$work/bin/tmux"
export PATH="$work/bin:$PATH" HOME="$work/home" DOLT_ROOT_PATH="$work/dolt-home"
# This suite may itself run inside a supervised session; start as a plain operator shell.
unset NOGG_SESSION_NAME NOGG_SESSION_ROLE NOGG_SESSION_AGENT NOGG_SESSION_ROOT NOGG_OPENSPEC_FENCE
mkdir -p "$HOME" "$DOLT_ROOT_PATH"

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out" "$err"; fail=1; }
expect() { [[ "$2" == "$3" ]] && ok "$1" || { echo "  got: $2 want: $3" >"$out"; bad "$1"; }; }
j() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2], {"d": d}))' "$out" "$1"; }

root="$work/repo"
mkdir -p "$root/.nogging/state/sessions" "$root/scripts"
cp "$repo_root/scripts/nogg" "$root/scripts/"
cp -r "$repo_root/scripts/lib" "$root/scripts/lib"
copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
git init -q -b develop "$root"
git -C "$root" -c user.name=Test -c user.email=test@example.org commit -q --allow-empty -m init
export NOGGING_ROOT="$root"
usage="$root/.nogging/state/token-usage"

record() {  # record <name> <profile> <pid>
  python3 - "$root/.nogging/state/sessions/$1.json" "$1" "$2" "$3" <<'PY'
import json, sys
path, name, profile, pid = sys.argv[1:5]
start = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()[19]
json.dump({"name": name, "role": "lead", "agent": "claude", "state": "running", "profile": profile,
           "floor_lifted": False, "session_pid": int(pid), "session_pid_start": start,
           "started_at": "2026-10-11T10:00:00+00:00", "working_dir": "/nonexistent"}, open(path, "w"))
PY
}

# --- authority -------------------------------------------------------------------
refused() {  # refused <label> <text> <env...>
  local label="$1" text="$2"; shift 2
  if env "$@" "$nogg" token-usage sync >"$out" 2>&1; then bad "$label should be refused"
  else grep -qF -- "$text" "$out" && ok "$label refused" || bad "$label refusal text"; fi
}
record sf-restricted restricted 1
refused "unproven session name (env spoof)" "cannot prove its authority" NOGG_SESSION_NAME=sf-restricted
refused "unknown session name" "not a known supervised session" NOGG_SESSION_NAME=sf-ghost
# Ancestry: this test shell plays a session's process.
record sf-ancestor restricted $$
refused "restricted session (ancestry, env stripped)" "session sf-ancestor runs profile 'restricted'" -u NOGG_SESSION_NAME
refused "restricted session (ancestry and env)" "runs profile 'restricted'" NOGG_SESSION_NAME=sf-ancestor
record sf-trusted trusted 1
refused "restricted process claiming a trusted name" "but this process runs inside sf-ancestor" NOGG_SESSION_NAME=sf-trusted
if env -u NOGG_SESSION_NAME "$nogg" token-usage import --file /dev/null >"$out" 2>&1; then bad "restricted import should be refused"
else grep -qF "needs trusted operator or orchestrator authority" "$out" && ok "restricted import refused" || bad "import refusal text"; fi
rm "$root/.nogging/state/sessions/sf-ancestor.json"
record sf-trusted trusted $$
NOGG_SESSION_NAME=sf-trusted "$nogg" token-usage sync >"$out" 2>&1 && bad "sync without a store should fail" \
  || { grep -qF "no local usage store yet" "$out" && ok "trusted session (ancestry) passes authority" || bad "trusted text"; }
rm "$root/.nogging/state/sessions/sf-trusted.json"
"$nogg" token-usage sync >"$out" 2>&1 && bad "operator sync without a store should fail" \
  || { grep -qF "no local usage store yet" "$out" && ok "operator passes authority" || bad "operator text"; }

# --- collect/report never contact the remote --------------------------------------
python3 - "$root" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts/lib")
from pathlib import Path
from token_usage_store import Store
store = Store(sys.argv[1], lambda _: {"state_dir": sys.argv[1] + "/.nogging/state"})
store.initialize()
store.append([("usage_events", {"source_id": "claude:x", "event_id": "e", "revision": "v1", "source_ordinal": 0,
               "source_timestamp": "2026-10-11T10:00:00Z", "runtime": "claude", "model": "m",
               "input_tokens": 7, "output_tokens": 1})])
PY
mkdir "$work/unreachable"; chmod 000 "$work/unreachable"   # fetch and push cannot succeed
(cd "$usage/database" && dolt remote add origin "file://$work/unreachable")
"$nogg" token-usage collect --json >"$out" 2>"$err" && ok "collect works with an unreachable remote" || bad "collect"
"$nogg" token-usage report --from 2026-10-11 --to 2026-10-12 --json >"$out" 2>"$err" \
  && expect "report is local-only before any sync" "$(j 'd["sync"]["state"], d["sync"]["local_only"], d["rows"][0]["tokens"]["input_tokens"]')" \
       "('not_configured', True, 7)" || bad "report"
[[ ! -e "$usage/sync-status.json" ]] && ok "no remote contact or sync status from collect/report" || bad "sync status appeared"
"$nogg" token-usage sync --json >"$out" 2>"$err" && bad "unreachable sync should exit non-zero" \
  || expect "unreachable remote leaves sync pending" "$(j 'd["state"], d["local_only"]')" "('pending', True)"
"$nogg" doctor >"$out" 2>&1 || true
grep -qF "usage sync pending" "$out" && ok "doctor notes pending sync" || bad "doctor sync note"

# --- operator sync to a reachable remote ------------------------------------------
mkdir "$work/remote"
(cd "$usage/database" && dolt remote remove origin && dolt remote add origin "file://$work/remote")
"$nogg" token-usage sync --json >"$out" 2>"$err" \
  && expect "operator sync pushes" "$(j 'd["state"], d["caller"], d["remote"].startswith("file://")')" "('synchronized', 'operator', True)" \
  || bad "sync"
"$nogg" token-usage report --from 2026-10-11 --to 2026-10-12 --json >"$out" 2>"$err" \
  && expect "report shows synchronization freshness" "$(j 'd["sync"]["state"], d["sync"]["local_only"], bool(d["sync"]["last_success_at"])')" \
       "('synchronized', False, True)" || bad "report after sync"
"$nogg" token-usage status --json >"$out" 2>"$err" && expect "status shows sync" "$(j 'd["sync"]["state"]')" "synchronized" || bad "status"
"$nogg" token-usage sync >"$out" 2>&1 && grep -qF "usage sync: synchronized" "$out" && ok "text sync renders" || bad "text sync"

exit "$fail"
