#!/usr/bin/env bash
# Checks for scripts/hooks/pre-rebase (TASK-SLR-006, design Decision 9).
# Uses real git: a bare origin, a real checkout, `scripts/install-hooks` to put
# the hook in place, and a real `git rebase` / `git pull --rebase` as the caller.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
cleanup() { chmod -R u+w "$tmp" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }
check() { # check <description> <command...>
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# new_fixture <name> <upstream-touches-openspec: yes|no>
# Builds origin + a clone on branch `feature` with one local commit, after
# origin/main gained one more commit. Prints the clone path.
new_fixture() {
  local name=$1 touch=$2 origin="$tmp/$1-origin.git" seed="$tmp/$1-seed" clone="$tmp/$1"
  git init -q --bare -b main "$origin"
  git init -q -b main "$seed"
  mkdir -p "$seed/openspec" "$seed/scripts"
  echo spec >"$seed/openspec/spec.md"
  echo base >"$seed/code.txt"
  git -C "$seed" add -A
  git -C "$seed" commit -qm base
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -q origin main
  git clone -q "$origin" "$clone"
  mkdir -p "$clone/scripts/hooks"
  cp "$root/scripts/install-hooks" "$clone/scripts/install-hooks"
  cp "$root"/scripts/hooks/{commit-msg,pre-commit,pre-push,pre-rebase} "$clone/scripts/hooks/" 2>/dev/null || true
  (cd "$clone" && bash scripts/install-hooks >/dev/null)
  git -C "$clone" checkout -q -b feature
  echo local >"$clone/local.txt"
  git -C "$clone" add local.txt
  git -C "$clone" -c core.hooksPath=/dev/null commit -qm "local work"
  # upstream moves on
  if [[ $touch == yes ]]; then echo spec2 >"$seed/openspec/spec.md"; else echo base2 >"$seed/code.txt"; fi
  git -C "$seed" commit -qam upstream
  git -C "$seed" push -q origin main
  git -C "$clone" fetch -q origin
  printf '%s\n' "$clone"
}

snapshot() { git -C "$1" rev-parse HEAD; git -C "$1" status --porcelain; cat "$1/openspec/spec.md" "$1/code.txt"; }

# --- installation --------------------------------------------------------
c=$(new_fixture install no)
check "install-hooks installs an executable pre-rebase" test -x "$c/.git/hooks/pre-rebase"
check "the shipped hook is executable in the source tree" test -x "$root/scripts/hooks/pre-rebase"

# --- fenced + upstream touches openspec/ ---------------------------------
c=$(new_fixture fenced-rebase yes)
before=$(snapshot "$c")
rc=0; out=$(cd "$c" && NOGG_OPENSPEC_FENCED=1 git rebase origin/main 2>&1) || rc=$?
[[ $rc -ne 0 ]] && ok "fenced git rebase is refused (exit $rc)" || bad "fenced git rebase was allowed"
[[ "$(snapshot "$c")" == "$before" ]] && ok "fenced rebase wrote nothing (HEAD, status, files unchanged)" || bad "fenced rebase changed the worktree"
[[ ! -d "$c/.git/rebase-merge" && ! -d "$c/.git/rebase-apply" ]] && ok "no rebase state left behind" || bad "rebase state left behind"
grep -q 'worktree rebase' <<<"$out" && ok "message names the supported command" || bad "message missing 'worktree rebase': $out"

c=$(new_fixture fenced-pull yes)
before=$(snapshot "$c")
rc=0; out=$(cd "$c" && NOGG_OPENSPEC_FENCED=1 git pull --rebase origin main 2>&1) || rc=$?
[[ $rc -ne 0 ]] && ok "fenced git pull --rebase is refused (exit $rc)" || bad "fenced git pull --rebase was allowed"
[[ "$(snapshot "$c")" == "$before" ]] && ok "fenced pull --rebase wrote nothing" || bad "fenced pull --rebase changed the worktree"
grep -q 'worktree rebase' <<<"$out" && ok "pull --rebase message names the supported command" || bad "pull message missing 'worktree rebase': $out"

# --- openspec/ read-only without the env var ------------------------------
if [[ -w / ]] && [[ $(id -u) -eq 0 ]]; then
  echo "skip - read-only openspec/ cases (root ignores directory modes)"
else
  c=$(new_fixture readonly yes)
  before=$(snapshot "$c")
  chmod -R a-w "$c/openspec"
  rc=0; out=$(cd "$c" && git rebase origin/main 2>&1) || rc=$?
  chmod -R u+w "$c/openspec"
  [[ $rc -ne 0 ]] && ok "read-only openspec/ git rebase is refused (exit $rc)" || bad "read-only openspec/ rebase was allowed"
  [[ "$(snapshot "$c")" == "$before" ]] && ok "read-only refusal wrote nothing" || bad "read-only refusal changed the worktree"
  grep -q 'worktree rebase' <<<"$out" && ok "read-only message names the supported command" || bad "read-only message missing 'worktree rebase'"
fi

# --- rebases that cannot hurt are allowed ---------------------------------
c=$(new_fixture fenced-safe no)
rc=0; (cd "$c" && NOGG_OPENSPEC_FENCED=1 git rebase origin/main >/dev/null 2>&1) || rc=$?
[[ $rc -eq 0 ]] && ok "fenced rebase is allowed when upstream did not touch openspec/" || bad "fenced safe rebase refused (rc=$rc)"
check "the safe rebase really applied the upstream commit" test "$(cat "$c/code.txt")" = base2

c=$(new_fixture fenced-safe-pull no)
rc=0; (cd "$c" && NOGG_OPENSPEC_FENCED=1 git pull --rebase origin main >/dev/null 2>&1) || rc=$?
[[ $rc -eq 0 ]] && ok "fenced pull --rebase is allowed when upstream did not touch openspec/" || bad "fenced safe pull --rebase refused (rc=$rc)"

c=$(new_fixture writer yes)
rc=0; (cd "$c" && git rebase origin/main >/dev/null 2>&1) || rc=$?
[[ $rc -eq 0 ]] && ok "an unfenced caller that can write openspec/ may rebase" || bad "unfenced writable rebase refused (rc=$rc)"
check "the planner-style rebase applied the openspec/ change" test "$(cat "$c/openspec/spec.md")" = spec2

# --- shipped and prompted -------------------------------------------------
check "package.json ships the hook" grep -q '"scripts/hooks/pre-rebase"' "$root/package.json"
check "package.json ships this test" grep -q '"scripts/pre-rebase-guard.test.sh"' "$root/package.json"
manifest_has() {
  node -e "const m=require('$root/bin/lib/manifest');const a=[...m.verbatim].concat(m.executable);process.exit(['$1'].every(p=>a.includes(p))?0:1)"
}
if command -v node >/dev/null 2>&1; then
  check "payload manifest ships the hook" manifest_has scripts/hooks/pre-rebase
  check "payload manifest marks the hook executable" node -e "process.exit(require('$root/bin/lib/manifest').executable.includes('scripts/hooks/pre-rebase')?0:1)"
  check "payload manifest ships this test" manifest_has scripts/pre-rebase-guard.test.sh
else
  echo "skip - node not available; manifest checks"
fi
for p in no-autonomous-claim autonomous; do
  f="$root/.nogging/launch-prompts/$p.md"
  check "$p prompt names ./scripts/nogg worktree rebase" grep -q 'scripts/nogg worktree rebase' "$f"
  check "$p prompt forbids raw git rebase, merge and pull" grep -Eq 'git rebase`?, `?git merge`? or `?git pull' "$f"
  check "$p prompt forbids resetting a dirty tree" grep -q 'never reset' "$f"
done

exit $fail
