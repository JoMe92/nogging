#!/usr/bin/env bash
# Focused checks for scripts/hooks/pre-tool-use-lead-launch-guard (TASK-DAL-002/004).
#
# Self-contained: a scratch CLAUDE_PROJECT_DIR with its own .nogging/config.json
# and a stubbed `bd` on PATH (dep list <id> --json returns $BD_DEP_LIST_JSON,
# default `[]`), mirroring branch-name.test.sh's style.
set -euo pipefail

hook="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pre-tool-use-lead-launch-guard"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

root="$work/root"
mkdir -p "$root/.nogging"
printf '{"beads_command": "bd"}\n' > "$root/.nogging/config.json"

mkdir -p "$work/bin"
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

export PATH="$work/bin:$PATH"
export CLAUDE_PROJECT_DIR="$root"

fail=0

# run <expect-exit> <description> <command-string>
run() {
  local expect="$1" desc="$2" cmd="$3"
  local out rc=0
  out=$(printf '{"tool_input":{"command":%s}}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$cmd")" \
    | "$hook" 2>&1) || rc=$?
  if [[ "$rc" == "$expect" ]]; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (expected exit $expect, got $rc; output: $out)"
    fail=1
  fi
  REPLY_OUT="$out"
}

# --- a matching, blocked launch is refused (exit 2), naming the blocker ---
export BD_DEP_LIST_JSON='[{"id":"SPEC-blocker","status":"open"}]'
run 2 "blocked lead launch is refused" \
  "scripts/nogg session launch --role lead --bead SPEC-blocked"
if [[ "$REPLY_OUT" == *"SPEC-blocker"* ]]; then
  echo "ok   - blocked refusal names the blocking Bead"
else
  echo "FAIL - blocked refusal does not name the blocking Bead (got: $REPLY_OUT)"
  fail=1
fi

run 2 "blocked specialist launch is refused" \
  "scripts/nogg session launch --role specialist:backend-engineer --bead SPEC-blocked"
unset BD_DEP_LIST_JSON

# --- a matching but unblocked launch proceeds (exit 0) ---------------------
export BD_DEP_LIST_JSON='[]'
run 0 "unblocked lead launch proceeds" \
  "scripts/nogg session launch --role lead --bead SPEC-ok"
export BD_DEP_LIST_JSON='[{"id":"SPEC-blocker","status":"closed"}]'
run 0 "a closed-only dependency does not block" \
  "scripts/nogg session launch --role lead --bead SPEC-ok"
unset BD_DEP_LIST_JSON

# --- non-matching commands are unaffected -----------------------------------
export BD_DEP_LIST_JSON='[{"id":"SPEC-blocker","status":"open"}]'
run 0 "an unrelated Bash command is unaffected" "ls -la"
run 0 "a session launch for --role orchestrator is unaffected" \
  "scripts/nogg session launch --role orchestrator"
run 0 "a session command that is not a launch is unaffected" \
  "scripts/nogg session list"
unset BD_DEP_LIST_JSON

if [[ $fail -ne 0 ]]; then
  echo "pre-tool-use-lead-launch-guard checks failed" >&2
  exit 1
fi
echo "all pre-tool-use-lead-launch-guard checks passed"
