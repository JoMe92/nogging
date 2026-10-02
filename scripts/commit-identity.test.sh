#!/usr/bin/env bash
# Regression checks for distinct commit identities per Nogging persona
# (openspec/changes/agent-commit-identity), Tier 1 only (TASK-ACI-001..006):
#
#   - the persona roster loads from `.nogging/config.json`'s `personas` key,
#     and an unconfigured slug fails loudly rather than committing under no
#     identity (TASK-ACI-001).
#
# Later Tier-1 tasks append their own scenarios to this file as they land.
# TASK-ACI-003 (the orchestrator's own identity at `orchestrator run`
# startup) is covered in scripts/orchestrator.test.sh, which already drives
# that command end to end.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

fail=0
check()  { if grep -qF -- "$2" "$out"; then echo "ok   - $1"; else echo "FAIL - $1 (missing: $2)"; cat "$out"; fail=1; fi; }
refute() { if grep -qF -- "$2" "$out"; then echo "FAIL - $1 (present: $2)"; cat "$out"; fail=1; else echo "ok   - $1"; fi; }

mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list) cat "${BD_FIXTURE:?}" ;;
  *) echo "unexpected bd call: $*" >&2; exit 1 ;;
esac
STUB
cat >"$work/bin/dolt" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

# make_root <dir> — a minimal Nogging checkout with one change and a git repo.
make_root() {
  local r="$1"
  mkdir -p "$r/.nogging/state" "$r/.nogging/locks" "$r/openspec/changes/demo"
  cp "$repo_root/.nogging/config.json" "$r/.nogging/config.json"
  printf '%s\n' '# Tasks' '' '- [ ] TASK-DEMO-001 Do the demo thing' >"$r/openspec/changes/demo/tasks.md"
  printf '# Execution log\n' >"$r/openspec/changes/demo/execution-log.md"
  git -C "$r" init -q
  git -C "$r" config user.email operator@example.invalid
  git -C "$r" config user.name 'Operator'
  git -C "$r" add -A && git -C "$r" commit -q -m "chore: scratch root [SPEC-000]"
  git -C "$r" checkout -q -b work
}

# ===========================================================================
# Scenario: the persona roster loads as data; an unconfigured slug fails loud
# ===========================================================================
root="$work/roster"; make_root "$root"
roster_out=$(NOGGING_ROOT="$root" python3 - "$nogg" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_roster", sys.argv[1]).load_module()
name, email = m.persona_identity("lead")
assert (name, email) == ("Nogging Lead", "lead@nogging.bot"), (name, email)
print("ok   - roster: lead persona resolves to Nogging Lead <lead@nogging.bot>")
try:
    m.persona_identity("no-such-persona")
    print("FAIL - roster: unknown slug should have raised")
except RuntimeError:
    print("ok   - roster: an unconfigured persona slug raises rather than silently committing")
PY
)
echo "$roster_out" >"$out"
check "roster: lead persona resolves correctly" "ok   - roster: lead persona resolves to Nogging Lead"
check "roster: unknown persona raises" "ok   - roster: an unconfigured persona slug raises"
refute "roster: no FAIL lines" "FAIL"
unset NOGGING_ROOT

if [[ $fail -ne 0 ]]; then echo "commit-identity checks failed" >&2; exit 1; fi
echo "commit identity: ok"
