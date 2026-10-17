#!/usr/bin/env bash
# Installer output (bin/lib/report.js): a header, changes grouped by file class
# with counts, each path once, unchanged files counted, one review block for
# preserved and forced files, and --verbose for the per-file list. No network,
# no bd/Dolt, no tmux server, no real systemctl.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
cli="$root/bin/cli.js"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   - skipped (node not installed)"
  echo "all installer output checks passed"
  exit 0
fi

fail=0
check() { # <description> <test-expr...>
  local desc="$1"; shift
  if "$@"; then echo "ok   - $desc"; else echo "FAIL - $desc"; fail=1; fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

new_repo() { # <dir>
  mkdir -p "$1"
  git -C "$1" init -q
}

run() { # <repo> <args...>; stdout+stderr to $out, status to $status
  local repo="$1"; shift
  status=0
  out=$(cd "$repo" && NOGG_PREFLIGHT_TIMEOUT_MS=500 node "$cli" "$@" 2>&1) || status=$?
}

tree() { # <repo>: per-file hashes outside .git
  (cd "$1" && find . -type f -not -path './.git/*' | sort | xargs sha256sum)
}

flags=(--no-beads --no-hooks)
rules=.codex/rules/nogging.rules
version=$(node -p "require('$root/package.json').version")

# A line of the output that is a listed path: indented, then an action word, then a path.
listed() { grep -Eq '^    [a-z( -]+ +[A-Za-z0-9_.@/-]+/[A-Za-z0-9_.@/-]+$' <<<"$1"; }
lines() { printf '%s\n' "$1" | wc -l; }

# --- fresh init -------------------------------------------------------------
repo="$work/fresh/repo"; new_repo "$repo"
run "$repo" init "${flags[@]}"
check "fresh init: exits 0" test "$status" -eq 0
check "fresh init: header names version, command and repository" \
  grep -Fxq "Nogging $version — init in $repo" <<<"$out"
for cls in 'Tool scripts' 'Agent payloads' 'Reference docs' 'Scaffold' 'Merged configuration' 'Rendered units' 'Tracker and hooks'; do
  check "fresh init: class line '$cls' carries counts" \
    grep -Eq "^  $cls +[0-9]+ [a-z]+" <<<"$out"
done
check "fresh init: no individual file list" bash -c '! grep -Eq "^    [a-z( -]+ +[A-Za-z0-9_.@/-]+/[A-Za-z0-9_.@/-]+$" <<<"$1"' _ "$out"
check "fresh init: output under 40 lines" test "$(lines "$out")" -lt 40
check "fresh init: no output line repeated" \
  bash -c '[ -z "$(grep -v "^ *$" <<<"$1" | sort | uniq -d)" ]' _ "$out"

# --- re-init and update with no change --------------------------------------
before=$(tree "$repo")
run "$repo" init "${flags[@]}"
check "re-init: exits 0" test "$status" -eq 0
check "re-init: unchanged files are counted" grep -Eq '^  Tool scripts +[0-9]+ unchanged' <<<"$out"
check "re-init: no individual file list" bash -c '! grep -Eq "^    [a-z( -]+ +[A-Za-z0-9_.@/-]+/[A-Za-z0-9_.@/-]+$" <<<"$1"' _ "$out"
run "$repo" update "${flags[@]}"
check "update, no change: exits 0" test "$status" -eq 0
check "update, no change: header says already at the version" \
  grep -Fxq "Nogging $version — update in $repo (already at $version)" <<<"$out"
check "update, no change: unchanged files are counted" grep -Eq '^  Agent payloads +[0-9]+ unchanged' <<<"$out"
check "update, no change: no review block" bash -c '! grep -Fq "Needs your review" <<<"$1"' _ "$out"
check "update, no change: no file list" bash -c '! grep -Eq "^    [a-z( -]+ +[A-Za-z0-9_.@/-]+/[A-Za-z0-9_.@/-]+$" <<<"$1"' _ "$out"
check "update, no change: writes nothing" test "$before" = "$(tree "$repo")"

# --- a locally edited file is reported once ---------------------------------
printf '# my edit\n' >>"$repo/$rules"
run "$repo" update "${flags[@]}"
check "update after a local edit: exits 0" test "$status" -eq 0
check "update after a local edit: review block present" grep -Fxq 'Needs your review' <<<"$out"
check "update after a local edit: path mentioned on exactly one line" \
  test "$(grep -c "$rules" <<<"$out")" -eq 1
check "update after a local edit: line names the .nogging-new sibling" \
  grep -Fxq "  $rules — kept your edit; upstream in $rules.nogging-new" <<<"$out"
check "update after a local edit: not repeated under Warnings" \
  bash -c '! grep -Fq "Warnings" <<<"$1"' _ "$out"
check "update after a local edit: review and force instructions follow" \
  bash -c 'grep -Fq "Review each .nogging-new" <<<"$1" && grep -Fq "Re-run with --force" <<<"$1"' _ "$out"
check "update after a local edit: the edit is kept" grep -Fq '# my edit' "$repo/$rules"
check "update after a local edit: upstream written beside it" test -f "$repo/$rules.nogging-new"

# --- update --force ---------------------------------------------------------
run "$repo" update --force "${flags[@]}"
check "update --force: exits 0" test "$status" -eq 0
check "update --force: exactly one .orig line" test "$(grep -c '\.orig' <<<"$out")" -eq 1
check "update --force: the line names the backup" \
  grep -Fxq "  $rules — overwritten (--force); backup in $rules.orig" <<<"$out"
check "update --force: the backup holds the edit" grep -Fq '# my edit' "$repo/$rules.orig"

# --- remove --dry-run -------------------------------------------------------
before=$(tree "$repo")
run "$repo" remove --dry-run
check "remove --dry-run: exits 0" test "$status" -eq 0
check "remove --dry-run: header" grep -Fxq "Nogging — remove from $repo (dry run)" <<<"$out"
check "remove --dry-run: grouped, would-remove counts" grep -Eq '^  Tool scripts +[0-9]+ would remove' <<<"$out"
check "remove --dry-run: no file list" bash -c '! grep -Eq "^    [a-z( -]+ +[A-Za-z0-9_.@/-]+/[A-Za-z0-9_.@/-]+$" <<<"$1"' _ "$out"
check "remove --dry-run: writes nothing" test "$before" = "$(tree "$repo")"

# --- --verbose --------------------------------------------------------------
vrepo="$work/verbose/repo"; new_repo "$vrepo"
run "$vrepo" init --verbose "${flags[@]}"
check "verbose: exits 0" test "$status" -eq 0
listing=$(awk '/^    / {print $NF}' <<<"$out" | LC_ALL=C sort)
manifest_paths=$(cd "$vrepo" && node -e '
  const m = JSON.parse(require("fs").readFileSync(".nogging/installed-manifest.json", "utf8"));
  console.log(Object.keys(m.files).sort().join("\n"));
')
check "verbose: lists every manifest path" \
  bash -c 'missing=$(LC_ALL=C comm -13 <(printf "%s\n" "$1" | LC_ALL=C sort) <(printf "%s\n" "$2" | LC_ALL=C sort)); [ -z "$missing" ]' _ "$listing" "$manifest_paths"
check "verbose: no path listed twice" bash -c '[ -z "$(LC_ALL=C sort <<<"$1" | uniq -d)" ]' _ "$listing"

if [ "$fail" -ne 0 ]; then
  echo "installer output checks failed" >&2
  exit 1
fi
echo "all installer output checks passed"
