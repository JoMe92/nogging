#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/test-env.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

root="$scratch/repo"
remote="$scratch/origin.git"
tree="$scratch/lead"
mkdir -p "$root/.nogging/state/worktrees" "$root/.nogging/state/sessions" \
  "$root/openspec/changes/demo" "$root/scripts"
cp "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
git init -q --bare "$remote"
git init -q -b develop "$root"
git -C "$root" config user.name "Fixture Maintainer"
git -C "$root" config user.email maintainer@example.invalid
mkdir -p "$root/openspec/changes/demo"
printf '%s\n' '# Tasks' '' '- [ ] TASK-DEMO-001 Implement behavior' >"$root/openspec/changes/demo/tasks.md"
printf '%s\n' 'base' >"$root/code.txt"
git -C "$root" add -A
git -C "$root" commit -q -m 'chore: seed rebase fixture [SPEC-seed]'
git -C "$root" remote add origin "$remote"
git -C "$root" push -q -u origin develop
git -C "$root" worktree add -q -b fix/demo "$tree" origin/develop
git -C "$tree" config user.name 'Nogging Lead'
git -C "$tree" config user.email lead@example.invalid
printf '%s\n' 'lead change' >"$tree/lead.txt"
git -C "$tree" add lead.txt
git -C "$tree" commit -q -m 'fix: implement demo [SPEC-demo]'
printf '%s\n' '# Tasks' '' '- [x] TASK-DEMO-001 Implement behavior' >"$root/openspec/changes/demo/tasks.md"
mkdir -p "$root/openspec/changes/archive/2026-10-19-demo"
git -C "$root" mv openspec/changes/demo/tasks.md \
  openspec/changes/archive/2026-10-19-demo/tasks.md
git -C "$root" add -A
git -C "$root" commit -q -m 'docs: tick and archive task [SPEC-demo]'
git -C "$root" push -q origin develop
printf '{"path":"%s","branch":"fix/demo","kind":"implementation","state":"allocated"}\n' \
  "$tree" >"$root/.nogging/state/worktrees/implementation--spec-demo.json"

run_rebase() {
  (cd "$tree" && NOGGING_ROOT="$tree" "$repo_root/scripts/nogg" worktree rebase "$@")
}
run_rebase >"$scratch/rebase.out"
git -C "$tree" merge-base --is-ancestor origin/develop HEAD
[[ -f "$tree/openspec/changes/archive/2026-10-19-demo/tasks.md" ]]
grep -q '^- \[x\] TASK-DEMO-001' "$tree/openspec/changes/archive/2026-10-19-demo/tasks.md"
[[ -f "$tree/lead.txt" ]]
[[ "$(git -C "$tree" log -1 --format=%an)" == 'Nogging Lead' ]]
grep -q 'backup ref: refs/nogg/rebase-backup/fix/demo/' "$scratch/rebase.out"
[[ ! -e "$root/.nogging/state/rebase/implementation--spec-demo.json" ]]

# A second invocation is a no-op and leaves the commit and worktree untouched.
tip=$(git -C "$tree" rev-parse HEAD)
run_rebase >"$scratch/up-to-date.out"
grep -q 'already up to date' "$scratch/up-to-date.out"
[[ "$(git -C "$tree" rev-parse HEAD)" == "$tip" ]]

# Dirty trees are refused before fetch/rebase writes or journal creation.
printf '%s\n' 'unsaved' >"$tree/unsaved.txt"
if run_rebase >"$scratch/dirty.out" 2>&1; then
  echo 'dirty tree unexpectedly rebased' >&2; exit 1
fi
grep -q 'target worktree is dirty: unsaved.txt' "$scratch/dirty.out"
[[ ! -e "$root/.nogging/state/rebase/implementation--spec-demo.json" ]]
rm "$tree/unsaved.txt"

# A code conflict is left paused for the writer-side continue/abort commands.
printf '%s\n' 'lead side' >"$tree/code.txt"
git -C "$tree" add code.txt
git -C "$tree" commit -q -m 'fix: change code side [SPEC-demo]'
conflict_tip=$(git -C "$tree" rev-parse HEAD)
printf '%s\n' 'upstream side' >"$root/code.txt"
git -C "$root" add code.txt
git -C "$root" commit -q -m 'fix: change upstream side [SPEC-demo]'
git -C "$root" push -q origin develop
if run_rebase >"$scratch/conflict.out" 2>&1; then
  echo 'conflicting rebase unexpectedly succeeded' >&2; exit 1
fi
grep -q 'code rebase conflict paused' "$scratch/conflict.out"
[[ "$(git -C "$tree" rev-parse refs/heads/fix/demo)" == "$conflict_tip" ]]
[[ -d "$(git -C "$tree" rev-parse --absolute-git-dir)/rebase-merge" ]]
run_rebase --abort >"$scratch/abort.out"
[[ -z "$(git -C "$tree" status --porcelain)" ]]
[[ ! -e "$root/.nogging/state/rebase/implementation--spec-demo.json" ]]

# A live foreign session is refused without changing the branch.
printf '{"name":"other-lead","state":"running","working_dir":"%s"}\n' "$tree" \
  >"$root/.nogging/state/sessions/other.json"
tip=$(git -C "$tree" rev-parse HEAD)
if run_rebase >"$scratch/in-use.out" 2>&1; then
  echo 'worktree with a live foreign session unexpectedly rebased' >&2; exit 1
fi
grep -q 'active session other-lead' "$scratch/in-use.out"
[[ "$(git -C "$tree" rev-parse HEAD)" == "$tip" ]]
[[ ! -e "$root/.nogging/state/rebase/implementation--spec-demo.json" ]]

echo 'worktree rebase safety and real git fixtures: ok'
