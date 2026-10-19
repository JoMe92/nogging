#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/lib/test-env.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
root="$scratch/repo"; remote="$scratch/origin.git"; tree="$scratch/lead"
mkdir -p "$root/.nogging/state/worktrees" "$root/.nogging/state/sessions" "$root/openspec/changes/demo"
cp "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
git init -q --bare "$remote"; git init -q -b develop "$root"
git -C "$root" config user.name Maintainer; git -C "$root" config user.email maintainer@example.invalid
printf 'base\n' >"$root/code.txt"; printf 'base\n' >"$root/openspec/changes/demo/tasks.md"
git -C "$root" add -A; git -C "$root" commit -q -m 'chore: seed [SPEC-seed]'
git -C "$root" remote add origin "$remote"; git -C "$root" push -q -u origin develop
git -C "$root" worktree add -q -b refactor/demo "$tree" origin/develop
git -C "$tree" config user.name 'Nogging Lead'; git -C "$tree" config user.email lead@example.invalid
printf 'lead\n' >"$tree/code.txt"; git -C "$tree" add code.txt; git -C "$tree" commit -q -m 'fix: lead [SPEC-demo]'
printf 'upstream\n' >"$root/code.txt"; git -C "$root" add code.txt; git -C "$root" commit -q -m 'fix: upstream [SPEC-demo]'; git -C "$root" push -q origin develop
printf '{"path":"%s","branch":"refactor/demo","kind":"implementation","state":"allocated"}\n' "$tree" >"$root/.nogging/state/worktrees/implementation--spec-demo.json"
run_rebase() { (cd "$tree" && NOGGING_ROOT="$tree" "$repo_root/scripts/nogg" worktree rebase "$@"); }

# Code-only conflicts leave a genuine rebase paused; the writer continues it.
if run_rebase >"$scratch/code.out" 2>&1; then echo 'code conflict unexpectedly succeeded' >&2; exit 1; fi
grep -q 'code rebase conflict paused' "$scratch/code.out"
[[ -d "$(git -C "$tree" rev-parse --absolute-git-dir)/rebase-merge" ]]
grep -q '"phase": "paused"' "$root/.nogging/state/rebase/implementation--spec-demo.json"
printf 'resolved\n' >"$tree/code.txt"; git -C "$tree" add code.txt
run_rebase --continue >"$scratch/continue.out"
git -C "$tree" merge-base --is-ancestor origin/develop HEAD
[[ ! -e "$root/.nogging/state/rebase/implementation--spec-demo.json" ]]

# A second conflict can be safely abandoned and restores the original tip.
printf 'lead again\n' >"$tree/code.txt"; git -C "$tree" add code.txt; git -C "$tree" commit -q -m 'fix: lead again [SPEC-demo]'
tip=$(git -C "$tree" rev-parse HEAD)
printf 'upstream again\n' >"$root/code.txt"; git -C "$root" add code.txt; git -C "$root" commit -q -m 'fix: upstream again [SPEC-demo]'; git -C "$root" push -q origin develop
if run_rebase >/dev/null 2>&1; then echo 'second code conflict unexpectedly succeeded' >&2; exit 1; fi
run_rebase --abort >"$scratch/abort.out"
[[ "$(git -C "$tree" rev-parse HEAD)" == "$tip" ]]
[[ -z "$(git -C "$tree" status --porcelain)" ]]
if run_rebase --abort >"$scratch/no-pause.out" 2>&1; then echo '--abort without pause unexpectedly succeeded' >&2; exit 1; fi
grep -q 'no paused Nogging rebase' "$scratch/no-pause.out"
if run_rebase --continue >"$scratch/no-continue.out" 2>&1; then echo '--continue without pause unexpectedly succeeded' >&2; exit 1; fi
grep -q 'no paused Nogging rebase' "$scratch/no-continue.out"

# OpenSpec conflicts abort automatically and restore the pre-rebase tree.
spec_tree="$scratch/spec-lead"
git -C "$root" worktree add -q -b fix/spec-demo "$spec_tree" origin/develop
git -C "$spec_tree" config user.name 'Nogging Lead'; git -C "$spec_tree" config user.email lead@example.invalid
printf 'lead spec\n' >"$spec_tree/openspec/changes/demo/tasks.md"; git -C "$spec_tree" add -A; git -C "$spec_tree" commit -q -m 'docs: lead spec [SPEC-demo]'
printf '{"path":"%s","branch":"fix/spec-demo","kind":"implementation","state":"allocated"}\n' "$spec_tree" >"$root/.nogging/state/worktrees/spec-case.json"
tip=$(git -C "$spec_tree" rev-parse HEAD)
printf 'upstream spec\n' >"$root/openspec/changes/demo/tasks.md"; git -C "$root" add -A; git -C "$root" commit -q -m 'docs: upstream spec [SPEC-demo]'; git -C "$root" push -q origin develop
if (cd "$spec_tree" && NOGGING_ROOT="$spec_tree" "$repo_root/scripts/nogg" worktree rebase) >"$scratch/spec.out" 2>&1; then echo 'OpenSpec conflict unexpectedly succeeded' >&2; exit 1; fi
grep -q 'OpenSpec rebase conflict; aborted and restored' "$scratch/spec.out"
[[ "$(git -C "$spec_tree" rev-parse HEAD)" == "$tip" ]]
[[ -z "$(git -C "$spec_tree" status --porcelain)" ]]
[[ ! -e "$root/.nogging/state/rebase/spec-case.json" ]]
echo 'worktree rebase conflict policy: ok'
