#!/usr/bin/env bash
set -euo pipefail

source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'git -C "$repo" worktree remove --force "$plan_tree" 2>/dev/null || true; git -C "$repo" worktree remove --force "$impl_tree" 2>/dev/null || true; rm -rf "$scratch"' EXIT
repo="$scratch/repo"; remote="$scratch/origin.git"
plan_tree="$scratch/plan"; impl_tree="$scratch/implementation"
mkdir -p "$repo/.nogging/locks" "$repo/.nogging/state" "$repo/openspec/changes/demo" "$scratch/bin"
cp "$source_root/.nogging/config.json" "$repo/.nogging/config.json"
cp "$source_root/scripts/nogg" "$repo/nogg"
chmod +x "$repo/nogg"
printf '%s\n' '# Tasks' '' '- [ ] TASK-DEMO-001 Implement demo' >"$repo/openspec/changes/demo/tasks.md"
printf '%s\n' '.nogging/locks/' '.nogging/state/' >"$repo/.gitignore"
git -C "$repo" init -q
git -C "$repo" config user.email workflow@example.invalid
git -C "$repo" config user.name 'Workflow Test'
git -C "$repo" add -A
git -C "$repo" commit -q -m 'chore: seed workflow [SPEC-seed]'
git -C "$repo" branch -M develop
git init -q --bare "$remote"
git -C "$repo" remote add origin "$remote"
git -C "$repo" push -q -u origin develop

cat >"$scratch/bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == list ]]; then
  printf '%s\n' '[{"id":"SPEC-e2e","status":"in_progress","labels":["openspec:change:demo","openspec:task:TASK-DEMO-001"]}]'
  exit 0
fi
exit 1
STUB
cat >"$scratch/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == 'pr list'* ]]; then printf '%s\n' '[]'; exit 0; fi
if [[ "$*" == 'pr create'* ]]; then printf '%s\n' 'https://example.invalid/pr/1'; exit 0; fi
if [[ "$*" == *'pr checks'*'--required'* ]]; then printf '%s\n' '[]'; exit 1; fi
if [[ "$*" == 'pr checks'* ]]; then printf '%s\n' '[{"name":"tests","state":"COMPLETED","bucket":"pass"}]'; exit 0; fi
exit 1
STUB
cat >"$scratch/bin/dolt" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$scratch/bin/bd" "$scratch/bin/gh" "$scratch/bin/dolt"
export PATH="$scratch/bin:$PATH" NOGGING_ROOT="$repo"

"$repo/nogg" worktree plan demo auth-flow --path "$plan_tree" >/dev/null
git -C "$plan_tree" config user.email workflow@example.invalid
git -C "$plan_tree" config user.name 'Workflow Test'
printf '%s\n' 'planned' >"$plan_tree/plan-evidence.txt"
git -C "$plan_tree" add plan-evidence.txt
git -C "$plan_tree" commit -q -m 'docs: validated plan' -m 'Nogging-Writer: planning'
export NOGGING_ROOT="$plan_tree"
"$plan_tree/nogg" validate >/dev/null
export NOGGING_ROOT="$repo"
git -C "$repo" merge -q --ff-only plan/demo/auth-flow
git -C "$repo" push -q origin develop
"$repo/nogg" worktree cleanup plan--demo--auth-flow.json >/dev/null

"$repo/nogg" worktree implement SPEC-e2e feat/demo --path "$impl_tree" >/dev/null
git -C "$impl_tree" config user.email workflow@example.invalid
git -C "$impl_tree" config user.name 'Workflow Test'
printf '%s\n' 'implemented' >"$impl_tree/implementation.txt"
git -C "$impl_tree" add implementation.txt
git -C "$impl_tree" commit -q -m 'feat: implement demo [SPEC-e2e]'
export NOGGING_ROOT="$impl_tree"
mkdir -p "$impl_tree/.nogging/state"
"$impl_tree/nogg" pr open --plan demo --task TASK-DEMO-001 --validation scripts/test >/dev/null
sed -i 's/"initial_check_after": "[^"]*"/"initial_check_after": "2000-01-01T00:00:00+00:00"/' \
  "$impl_tree/.nogging/state/pull-requests/feat-demo.json"
"$impl_tree/nogg" pr ci | grep -q 'ready_for_user_review (all checks)'

export NOGGING_ROOT="$repo"
git -C "$repo" merge -q --ff-only feat/demo
"$repo/nogg" worktree cleanup implementation--spec-e2e.json >/dev/null
[[ ! -e "$plan_tree" && ! -e "$impl_tree" ]]
echo 'worktree workflow end-to-end: ok'
