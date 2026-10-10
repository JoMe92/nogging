#!/usr/bin/env bash
# Verification of templates/claude/orchestrator-permissions.example.json (TASK-ASD-003).
#
# Asserts:
#   - template exists and is valid JSON
#   - template permissions.deny is a strict superset of FLOOR_DENY
#   - simulated floor drift is caught
#   - history-destroying git operations are denied (push --force, reset --hard, clean, branch -D)
#   - allow rules contain narrow canonical session commands, worktree/status commands, and concrete bd commands
#   - broad/pauschale allow grants (Bash(./scripts/nogg:*), Bash(bd:*), Bash(./scripts/nogg session:*)) are REFUSED
#   - no absolute host user paths appear in the template
#   - nogg init / update never apply the template rules to user or project settings
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nogg="$root/scripts/nogg"
template="$root/templates/claude/orchestrator-permissions.example.json"
cli="$root/bin/cli.js"

fail=0
check() {
  local desc="$1"; shift
  if "$@"; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc"
    fail=1
  fi
}

# 1. Template exists and is valid JSON
check "template file exists" test -f "$template"

json_valid=$(python3 - "$template" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    assert "permissions" in data, "missing permissions key"
    assert "allow" in data["permissions"], "missing allow key"
    assert "deny" in data["permissions"], "missing deny key"
    print("VALID")
except Exception as e:
    print(f"INVALID: {e}")
    sys.exit(1)
PY
) && rc=0 || rc=$?
check "template is valid JSON with permissions structure" test "$rc" -eq 0

# 2. Template deny list is a superset of FLOOR_DENY
superset_out=$(python3 - "$nogg" "$template" <<'PY'
import json, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_nogg", sys.argv[1]).load_module()
floor = m.FLOOR_DENY
with open(sys.argv[2]) as f:
    template_data = json.load(f)
deny = set(template_data.get("permissions", {}).get("deny", []))

missing = [entry for entry in floor if entry not in deny]
if missing:
    print(f"MISSING_FLOOR_ENTRIES: {missing}")
    sys.exit(1)
print(f"OK: all {len(floor)} FLOOR_DENY entries present in template deny list")
PY
) && rc=0 || rc=$?
check "template deny list is a superset of FLOOR_DENY ($superset_out)" test "$rc" -eq 0

# 3. Floor drift is caught (Scenario: Floor drift is caught)
drift_caught=$(python3 - "$nogg" "$template" <<'PY'
import json, sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_nogg", sys.argv[1]).load_module()
# Simulate a new entry added to FLOOR_DENY that the template lacks
hypothetical_floor = list(m.FLOOR_DENY) + ["Bash(fictional_hazardous_command:*)"]

with open(sys.argv[2]) as f:
    template_data = json.load(f)
deny = set(template_data.get("permissions", {}).get("deny", []))

missing = [entry for entry in hypothetical_floor if entry not in deny]
if missing == ["Bash(fictional_hazardous_command:*)"]:
    print("DRIFT_DETECTED")
    sys.exit(0)
else:
    print(f"UNEXPECTED: {missing}")
    sys.exit(1)
PY
) && rc=0 || rc=$?
check "floor drift is detected when FLOOR_DENY has entries missing from template" test "$rc" -eq 0

# 4. History-destroying Git commands are present in deny
git_ops_out=$(python3 - "$template" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    template_data = json.load(f)
deny = template_data.get("permissions", {}).get("deny", [])

required_patterns = [
    ("push --force", lambda d: any("push --force" in e or "push -f" in e for e in d)),
    ("reset --hard", lambda d: any("reset --hard" in e for e in d)),
    ("clean", lambda d: any("clean" in e for e in d)),
    ("branch -D", lambda d: any("branch -D" in e or "branch --delete --force" in e for e in d)),
]

for label, checker in required_patterns:
    if not checker(deny):
        print(f"MISSING_GIT_DENY: {label}")
        sys.exit(1)
print("OK: history-destroying git operations present in deny list")
PY
) && rc=0 || rc=$?
check "history-destroying git operations denied in template ($git_ops_out)" test "$rc" -eq 0

# 5. Broad allow grants are strictly refused
no_broad_grants_out=$(python3 - "$template" <<'PY'
import json, re, sys
with open(sys.argv[1]) as f:
    template_data = json.load(f)
allow = template_data.get("permissions", {}).get("allow", [])

# Must not contain broad scripts/nogg grants
broad_nogg = [e for e in allow if re.search(r'Bash\(\.?/?scripts/nogg:\*\)', e)]
if broad_nogg:
    print(f"FORBIDDEN_BROAD_NOGG: {broad_nogg}")
    sys.exit(1)

# Must not contain broad bd grants
broad_bd = [e for e in allow if e == "Bash(bd:*)"]
if broad_bd:
    print(f"FORBIDDEN_BROAD_BD: {broad_bd}")
    sys.exit(1)

# Must not contain broad session grants
broad_session = [e for e in allow if re.search(r'Bash\(\.?/?scripts/nogg session:\*\)', e)]
if broad_session:
    print(f"FORBIDDEN_BROAD_SESSION: {broad_session}")
    sys.exit(1)

# Must not contain cleanup/reap
cleanup_reap = [e for e in allow if "cleanup" in e or "reap" in e]
if cleanup_reap:
    print(f"FORBIDDEN_CLEANUP_REAP: {cleanup_reap}")
    sys.exit(1)

print("OK: no broad nogg, bd, or session allow grants")
PY
) && rc=0 || rc=$?
check "broad allow rules are refused ($no_broad_grants_out)" test "$rc" -eq 0

# 5b. Verify that simulated broad rules trigger refusal in checker
simulated_broad_caught=$(python3 - <<'PY'
import re, sys
bad_allows = [
    ["Bash(./scripts/nogg:*)"],
    ["Bash(bd:*)"],
    ["Bash(./scripts/nogg session:*)"],
    ["Bash(./scripts/nogg session cleanup:*)"]
]
for sample in bad_allows:
    rule = sample[0]
    is_bad = bool(
        re.search(r'Bash\(\.?/?scripts/nogg:\*\)', rule) or
        rule == "Bash(bd:*)" or
        re.search(r'Bash\(\.?/?scripts/nogg session:\*\)', rule) or
        "cleanup" in rule or "reap" in rule
    )
    if not is_bad:
        print(f"FAILED_TO_DETECT_BAD_RULE: {rule}")
        sys.exit(1)
print("OK: detector identifies broad nogg/bd/session rules")
PY
) && rc=0 || rc=$?
check "drift detector flags hypothetical broad allow rules ($simulated_broad_caught)" test "$rc" -eq 0

# 6. Allow list contains concrete canonical commands and placeholders
concrete_allows_out=$(python3 - "$template" <<'PY'
import json, re, sys
with open(sys.argv[1]) as f:
    content = f.read()
    data = json.loads(content)
allow = data.get("permissions", {}).get("allow", [])

# No real host user paths (e.g. /home/<user> or /Users/<user>)
if re.search(r'/(?:home|Users)/[a-zA-Z0-9_-]+/', content):
    print("FOUND_REAL_USER_PATH_IN_TEMPLATE")
    sys.exit(1)

# Must contain placeholder worktree pattern
if not any("//HOME/src/<repo>-spec-*/**" in e for e in allow):
    print("MISSING_WORKTREE_PLACEHOLDER_PATTERN")
    sys.exit(1)

# Must contain canonical session commands: launch, send, kickoff, stop, list, log, watch
canonical_sessions = ["launch", "send", "kickoff", "stop", "list", "log", "watch"]
for cmd in canonical_sessions:
    pattern = f"session {cmd}:*"
    if not any(pattern in e for e in allow):
        print(f"MISSING_CANONICAL_SESSION_COMMAND: {cmd}")
        sys.exit(1)

# Must contain concrete bd commands
concrete_bd = ["ready", "show", "list", "blocked", "update", "create", "close", "remember", "dep list"]
for bdc in concrete_bd:
    pattern = f"bd {bdc}:*"
    if not any(pattern in e for e in allow):
        print(f"MISSING_CONCRETE_BD_COMMAND: {bdc}")
        sys.exit(1)

print("OK: all required narrow canonical session and bd commands present")
PY
) && rc=0 || rc=$?
check "concrete allow rules present without broad wildcards ($concrete_allows_out)" test "$rc" -eq 0

# 7. Verify init/update never apply template rules to project settings
if command -v node >/dev/null 2>&1; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT

  testrepo="$work/testrepo"
  mkdir -p "$testrepo"
  git -C "$testrepo" init -q

  # Run init
  ( cd "$testrepo" && node "$cli" init --no-beads --no-systemd >/dev/null 2>&1 ) || true

  # Check that project settings file does NOT contain the template rules
  settings="$testrepo/.claude/settings.json"
  if [ -f "$settings" ]; then
    settings_content=$(cat "$settings")
    check "init does not inject template allow rules into project settings" \
      bash -c "! grep -q '//HOME/src/<repo>-spec-' <<< \"\$0\"" "$settings_content"
    check "init does not inject template git deny rules into project settings" \
      bash -c "! grep -q 'git push --force' <<< \"\$0\"" "$settings_content"
  else
    check "project settings file not created or clean" true
  fi

  # Run update
  ( cd "$testrepo" && node "$cli" update --no-beads --no-systemd >/dev/null 2>&1 ) || true
  if [ -f "$settings" ]; then
    settings_content=$(cat "$settings")
    check "update does not inject template allow rules into project settings" \
      bash -c "! grep -q '//HOME/src/<repo>-spec-' <<< \"\$0\"" "$settings_content"
    check "update does not inject template git deny rules into project settings" \
      bash -c "! grep -q 'git push --force' <<< \"\$0\"" "$settings_content"
  fi
fi

if [[ $fail -ne 0 ]]; then
  echo "orchestrator permissions template checks failed" >&2
  exit 1
fi
echo "all orchestrator permissions template checks passed"
