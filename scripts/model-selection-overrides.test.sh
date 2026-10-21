#!/usr/bin/env bash
# Project tier effort overrides for the public models command (TASK-TEO-001).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
nogg="$here/nogg"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT
fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

make_root() {
  local r="$1"
  mkdir -p "$r/.nogging"
  git init -q "$r"
  copy_host_config "$repo_root/.nogging/config.json" "$r/.nogging/config.json"
  cp "$repo_root/templates/model-selection.json" "$r/.nogging/model-selection.json"
}
models() { NOGGING_ROOT="$1" "$nogg" models "${@:2}"; }
set_override() {
  python3 - "$1/.nogging/config.json" "$2" "$3" "$4" <<'PY'
import json, sys
p, tier, agent, effort = sys.argv[1:]
c = json.load(open(p))
c['tier_overrides'] = {tier: {agent: {'effort': effort}}}
open(p, 'w').write(json.dumps(c, indent=2) + '\n')
PY
}

r="$work/override"; make_root "$r"; set_override "$r" complex codex medium
if models "$r" --agent codex --tier complex >"$out" 2>&1 \
  && grep -q 'model=gpt-6.1-sol effort=medium (project; table low)' "$out"; then
  ok "text lookup shows project override and table effort"
else bad "text lookup shows project override and table effort"; fi
if models "$r" --agent codex --tier complex --json >"$out" 2>&1 && python3 - "$out" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
assert e['effort'] == 'medium' and e['table_effort'] == 'low' and e['effort_source'] == 'project', e
PY
then ok "JSON lookup exposes effective and table effort"; else bad "JSON lookup exposes effective and table effort"; fi
if models "$r" --json >"$out" 2>&1 && python3 - "$out" "$repo_root/templates/model-selection.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1])) == json.load(open(sys.argv[2]))
PY
then ok "unfiltered JSON stays the shipped table"; else bad "unfiltered JSON stays the shipped table"; fi
if models "$r" --agent codex --tier standard --json >"$out" 2>&1 && python3 - "$out" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
assert e['effort'] == 'medium' and e['table_effort'] == 'medium' and e['effort_source'] == 'table', e
PY
then ok "unoverridden JSON identifies the table effort"; else bad "unoverridden JSON identifies the table effort"; fi
if models "$r" check >"$out" 2>&1 && grep -q '1 tier override' "$out"; then
  ok "models check counts overrides"
else bad "models check counts overrides"; fi

for pair in 'claude routine low' 'codex standard medium'; do
  read -r agent tier effort <<<"$pair"
  r="$work/$agent-$tier"; make_root "$r"; set_override "$r" "$tier" "$agent" "$effort"
  table_effort=$(python3 - "$repo_root/templates/model-selection.json" "$agent" "$tier" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))['agents'][sys.argv[2]][sys.argv[3]]['effort'])
PY
)
  if models "$r" --agent "$agent" --tier "$tier" >"$out" 2>&1 \
    && grep -q "(project; table $table_effort)" "$out"; then
    ok "table-equal $agent $tier override retains project provenance"
  else bad "table-equal $agent $tier override retains project provenance"; fi
done

reject() {
  local name="$1" block="$2" expected="$3" r="$work/bad-$RANDOM$RANDOM"
  make_root "$r"
  python3 - "$r/.nogging/config.json" "$block" <<'PY'
import json, sys
p, raw = sys.argv[1:]
c = json.load(open(p)); c['tier_overrides'] = json.loads(raw)
open(p, 'w').write(json.dumps(c))
PY
  if models "$r" check >"$out" 2>&1; then bad "$name accepted"; return; fi
  if grep -qF "$expected" "$out"; then ok "$name refused by name"; else bad "$name error names offending key"; fi
  if models "$r" --agent claude --tier routine >"$out" 2>&1; then bad "$name lookup accepted"; fi
}
reject "unknown tier" '{"trivial":{"codex":{"effort":"low"}}}' 'tier_overrides: unknown tier'
reject "unknown agent" '{"routine":{"pi":{"effort":"low"}}}' 'tier_overrides.routine: unknown agent'
reject "unsupported alias" '{"routine":{"agy":{"effort":"low"}}}' 'tier_overrides.routine: unknown agent'
reject "Antigravity" '{"routine":{"antigravity":{"effort":"low"}}}' 'tier_overrides.routine.antigravity: effort is not allowed'
reject "unknown key" '{"routine":{"codex":{"effort":"low","model":"x"}}}' 'tier_overrides.routine.codex: unknown key'
reject "missing effort" '{"routine":{"codex":{}}}' "tier_overrides.routine.codex: missing key 'effort'"
reject "invalid effort" '{"complex":{"codex":{"effort":"turbo"}}}' 'tier_overrides.complex.codex.effort: '
reject "invalid Claude effort" '{"complex":{"claude":{"effort":"ultra"}}}' 'tier_overrides.complex.claude.effort: '
reject "non-object block" '[]' 'tier_overrides: must be an object'

if python3 - "$repo_root/templates/nogging-config.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1]))['tier_overrides'] == {}
PY
then ok "config scaffold includes an empty tier_overrides object"
else bad "config scaffold includes an empty tier_overrides object"; fi

exit "$fail"
