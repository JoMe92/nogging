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

unset NOGGING_ROOT

# ===========================================================================
# Scenario: worktree plan sets the planner identity inside the new worktree
# ===========================================================================
root="$work/wt-plan"; make_root "$root"
remote="$work/wt-plan-origin.git"; git init -q --bare "$remote"
git -C "$root" branch develop
git -C "$root" remote add origin "$remote"
git -C "$root" push -q origin develop
export NOGGING_ROOT="$root"
destination="$work/wt-plan-destination"
"$nogg" worktree plan agent-identity commit-identity --path "$destination" >"$out" 2>&1 \
  || { echo "FAIL - wt-plan: allocation errored"; cat "$out"; fail=1; }
[[ "$(git -C "$destination" config --worktree --get user.name)" == "Nogging Planner" ]] \
  && echo "ok   - wt-plan: worktree-scoped user.name is Nogging Planner" \
  || { echo "FAIL - wt-plan: user.name is $(git -C "$destination" config --get user.name 2>/dev/null || echo unset)"; fail=1; }
[[ "$(git -C "$destination" config --worktree --get user.email)" == "planner@nogging.bot" ]] \
  && echo "ok   - wt-plan: worktree-scoped user.email is planner@nogging.bot" \
  || { echo "FAIL - wt-plan: user.email is $(git -C "$destination" config --get user.email 2>/dev/null || echo unset)"; fail=1; }
[[ "$(git -C "$root" config --get extensions.worktreeConfig)" == "true" ]] \
  && echo "ok   - wt-plan: extensions.worktreeConfig enabled on the shared repo" \
  || { echo "FAIL - wt-plan: extensions.worktreeConfig not enabled"; fail=1; }
[[ "$(git -C "$root" config --get user.name)" == "Operator" ]] \
  && echo "ok   - wt-plan: the shared checkout's own identity is untouched" \
  || { echo "FAIL - wt-plan: shared checkout identity changed to $(git -C "$root" config --get user.name)"; fail=1; }
printf 'planned\n' >"$destination/plan-evidence.txt"
git -C "$destination" add plan-evidence.txt
git -C "$destination" commit -q -m 'docs: validated plan' -m 'Nogging-Writer: planning'
[[ "$(git -C "$destination" log -1 --format='%an <%ae>')" == "Nogging Planner <planner@nogging.bot>" ]] \
  && echo "ok   - wt-plan: a commit made with no author flag carries the planner identity" \
  || { echo "FAIL - wt-plan: commit author is $(git -C "$destination" log -1 --format='%an <%ae>')"; fail=1; }
git -C "$root" worktree remove --force "$destination"
unset NOGGING_ROOT

# ===========================================================================
# Scenario: worktree implement sets the lead identity inside the new worktree
# ===========================================================================
root="$work/wt-implementation"; make_root "$root"
remote="$work/wt-implementation-origin.git"; git init -q --bare "$remote"
git -C "$root" branch develop
git -C "$root" remote add origin "$remote"
git -C "$root" push -q origin develop
export NOGGING_ROOT="$root"
export BD_FIXTURE="$work/wt-implementation-beads.json"
printf '[{"id":"SPEC-impl","status":"in_progress","labels":[]}]\n' >"$BD_FIXTURE"
destination="$work/wt-implementation-destination"
"$nogg" worktree implement SPEC-impl feat/demo --path "$destination" >"$out" 2>&1 \
  || { echo "FAIL - wt-implementation: allocation errored"; cat "$out"; fail=1; }
[[ "$(git -C "$destination" config --worktree --get user.name)" == "Nogging Lead" ]] \
  && echo "ok   - wt-implementation: worktree-scoped user.name is Nogging Lead" \
  || { echo "FAIL - wt-implementation: user.name is $(git -C "$destination" config --get user.name 2>/dev/null || echo unset)"; fail=1; }
[[ "$(git -C "$destination" config --worktree --get user.email)" == "lead@nogging.bot" ]] \
  && echo "ok   - wt-implementation: worktree-scoped user.email is lead@nogging.bot" \
  || { echo "FAIL - wt-implementation: user.email is $(git -C "$destination" config --get user.email 2>/dev/null || echo unset)"; fail=1; }
git -C "$root" worktree remove --force "$destination"
unset NOGGING_ROOT BD_FIXTURE

unset NOGGING_ROOT BD_FIXTURE

# ===========================================================================
# Scenario: the sync mirror commit carries the Nogging Sync identity
# ===========================================================================
root="$work/sync-identity"; make_root "$root"
git -C "$root" commit -q --allow-empty -m "feat(demo): first demo thing [SPEC-d01]"
export NOGGING_ROOT="$root"
export BD_FIXTURE="$work/sync-identity-beads.json"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-d01", "status": "closed",
   "closed_at": "2026-09-01T10:00:00Z", "updated_at": "2026-09-01T10:00:00Z",
   "notes": "commit abc1234; implemented the first demo thing",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
"$nogg" sync >"$out" 2>&1 || { echo "FAIL - sync-identity: sync errored"; cat "$out"; fail=1; }
[[ "$(git -C "$root" log -1 --format='%an <%ae>')" == "Nogging Sync <sync@nogging.bot>" ]] \
  && echo "ok   - sync-identity: mirror commit author is Nogging Sync" \
  || { echo "FAIL - sync-identity: commit author is $(git -C "$root" log -1 --format='%an <%ae>')"; fail=1; }
[[ "$(git -C "$root" log -1 --format='%cn <%ce>')" == "Nogging Sync <sync@nogging.bot>" ]] \
  && echo "ok   - sync-identity: mirror commit committer is Nogging Sync" \
  || { echo "FAIL - sync-identity: commit committer is $(git -C "$root" log -1 --format='%cn <%ce>')"; fail=1; }
unset NOGGING_ROOT BD_FIXTURE

unset NOGGING_ROOT BD_FIXTURE

# ===========================================================================
# Scenario: doctor NOTEs a worktree whose identity doesn't match its persona
# ===========================================================================
root="$work/doctor-mismatch"; make_root "$root"
remote="$work/doctor-mismatch-origin.git"; git init -q --bare "$remote"
git -C "$root" branch develop
git -C "$root" remote add origin "$remote"
git -C "$root" push -q origin develop
export NOGGING_ROOT="$root"
export BD_FIXTURE="$work/doctor-mismatch-beads.json"; printf '[]\n' >"$BD_FIXTURE"
destination="$work/doctor-mismatch-destination"
"$nogg" worktree plan agent-identity doctor-note --path "$destination" >/dev/null 2>&1
"$nogg" doctor >"$out" 2>&1 || true
refute "doctor-mismatch: no NOTE while the identity matches its persona" \
  "user.name is Nogging Planner, expected Nogging Planner"
# simulate a pre-change worktree / silently failed identity-set
git -C "$destination" config --worktree user.name 'Workflow Test'
"$nogg" doctor >"$out" 2>&1 || true
check "doctor-mismatch: NOTEs a worktree whose user.name does not match its persona" \
  "user.name is Workflow Test, expected Nogging Planner"
git -C "$root" worktree remove --force "$destination"
unset NOGGING_ROOT BD_FIXTURE

if [[ $fail -ne 0 ]]; then echo "commit-identity checks failed" >&2; exit 1; fi
echo "commit identity: ok"
