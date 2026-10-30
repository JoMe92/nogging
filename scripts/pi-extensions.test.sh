#!/usr/bin/env bash
# Offline runner for Nogging's optional Pi extensions under .pi/nogging/.
#
# 1. Lint (bash and grep/awk only, no Node): each extension directory is
#    kebab-case with an index.ts and a README index entry, no package.json
#    exists, runtime imports are node: built-ins or relative .ts paths, Pi
#    is imported only as a type, and only erasable TypeScript is used.
# 2. Tests: every *.test.ts runs with `node --test` and Node's type stripping,
#    under temporary HOME, XDG_CACHE_HOME and PI_CODING_AGENT_DIR. No Pi,
#    network or build step is needed.
#
# When node is missing or cannot strip types, the lint still runs, the tests
# are reported as skipped and the runner passes (matching scripts/pi-guard.test.sh).
#
# Usage: pi-extensions.test.sh [--home <dir>] [--lint-only]
#   --home       the extension home to check (default: <repo>/.pi/nogging);
#                scripts/pi-extensions-lint.test.sh points it at throwaway trees.
#   --lint-only  skip the Node test step.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/test-env.sh"

home="$root/.pi/nogging"
lint_only=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --home) home=${2:?--home needs a directory}; shift 2 ;;
    --lint-only) lint_only=1; shift ;;
    *) echo "usage: $0 [--home <dir>] [--lint-only]" >&2; exit 2 ;;
  esac
done

failures=0
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }
ok() { echo "ok   - $1"; }

if [[ ! -d $home ]]; then
  fail "extension home $home does not exist"
  exit 1
fi

rel() { echo "${1#"$home"/}"; }

# --- lint: layout --------------------------------------------------------

readme="$home/README.md"
[[ -f $readme ]] || fail "README.md is missing from $home"

extensions=()
if [[ -d $home/extensions ]]; then
  while IFS= read -r d; do
    extensions+=("$d")
  done < <(find "$home/extensions" -mindepth 1 -maxdepth 1 -type d | sort)
fi

for d in "${extensions[@]}"; do
  name=$(basename "$d")
  # Fixtures may land ahead of their extension: a directory holding nothing but
  # test/ is not an extension yet.
  if [[ -z $(find "$d" -mindepth 1 -maxdepth 1 -not -name test) ]]; then
    continue
  fi
  if ! [[ $name =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    fail "extensions/$name: directory name is not kebab-case"
  fi
  [[ -f $d/index.ts ]] || fail "extensions/$name: index.ts is missing"
  if [[ -f $readme ]] && ! grep -Fq -- "\`$name\`" "$readme"; then
    fail "extensions/$name: README.md has no index entry (expected \`$name\`)"
  fi
done

while IFS= read -r p; do
  fail "$(rel "$p"): package.json is not allowed under .pi/nogging/"
done < <(find "$home" -name package.json -not -path '*/node_modules/*' | sort)

# --- lint: imports and syntax -------------------------------------------

# Prints "<line>:<kind>:<specifier>" for every module specifier in a file.
# kind is "type" for `import type ...` and "value" for everything else
# (including `import { type X } from`, which Node still resolves at runtime).
# A multi-line import statement is joined until its `from "<spec>"` line.
scan_imports() {
  awk '
    function emit(stmt, line,   spec, kind) {
      if (match(stmt, /(from[ \t]*|import[ \t]*)["\x27][^"\x27]+["\x27]/)) {
        spec = substr(stmt, RSTART, RLENGTH)
        sub(/^(from|import)[ \t]*["\x27]/, "", spec)
        sub(/["\x27]$/, "", spec)
        kind = (stmt ~ /^[ \t]*import[ \t]+type[ \t{*]/) ? "type" : "value"
        print line ":" kind ":" spec
      }
    }
    /^[ \t]*export[ \t].*[ \t]from[ \t]*["\x27]/ { emit($0, NR); next }
    /^[ \t]*import[ \t]*["\x27]/ { emit($0, NR); next }
    /^[ \t]*import[ \t{*]/ || /^[ \t]*import[ \t]+[A-Za-z_$]/ {
      if ($0 ~ /["\x27][^"\x27]+["\x27]/) { emit($0, NR) }
      else { stmt = $0; start = NR; pending = 1 }
      next
    }
    pending {
      stmt = stmt " " $0
      if ($0 ~ /from[ \t]*["\x27][^"\x27]+["\x27]/) { emit(stmt, start); pending = 0 }
      next
    }
    { s = $0
      while (match(s, /[^A-Za-z0-9_.$]import[ \t]*\([ \t]*["\x27][^"\x27]+["\x27]/)) {
        d = substr(s, RSTART, RLENGTH)
        sub(/^[^i]*import[ \t]*\([ \t]*["\x27]/, "", d)
        sub(/["\x27]$/, "", d)
        print NR ":value:" d
        s = substr(s, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

while IFS= read -r f; do
  while IFS=: read -r line kind spec; do
    [[ -n $line ]] || continue
    [[ $kind == type ]] && continue
    case $spec in
      node:*) ;;
      ./*.ts | ../*.ts) ;;
      @earendil-works/*)
        fail "$(rel "$f"):$line: non-type import of Pi package \"$spec\" (use import type)" ;;
      ./* | ../*)
        fail "$(rel "$f"):$line: relative import \"$spec\" needs an explicit .ts extension" ;;
      *)
        fail "$(rel "$f"):$line: bare runtime import \"$spec\" (only node: built-ins and relative .ts paths)" ;;
    esac
  done < <(scan_imports "$f")

  # Erasable TypeScript only: Node type stripping cannot lower these.
  while IFS=: read -r line _; do
    fail "$(rel "$f"):$line: enum is not erasable TypeScript"
  done < <(grep -nE '^[[:space:]]*(export[[:space:]]+)?(declare[[:space:]]+)?(const[[:space:]]+)?enum[[:space:]]+[A-Za-z_]' "$f" || true)
  while IFS=: read -r line _; do
    fail "$(rel "$f"):$line: namespace/module block is not erasable TypeScript"
  done < <(grep -nE '^[[:space:]]*(export[[:space:]]+)?(declare[[:space:]]+)?namespace[[:space:]]+[A-Za-z_]' "$f" || true)
  while IFS=: read -r line _; do
    fail "$(rel "$f"):$line: constructor parameter property is not erasable TypeScript"
  done < <(grep -nE 'constructor[[:space:]]*\([^)]*(public|private|protected|readonly)[[:space:]]+[A-Za-z_]' "$f" || true)
done < <(find "$home" -name '*.ts' -type f | sort)

if [[ $failures -eq 0 ]]; then
  ok "layout and import conventions"
else
  echo "$failures lint failure(s)"
  exit 1
fi

[[ $lint_only == 1 ]] && { echo "all pi-extensions lint checks passed"; exit 0; }

# --- tests ---------------------------------------------------------------

tests=()
while IFS= read -r t; do
  tests+=("$t")
done < <(find "$home" -name '*.test.ts' -type f | sort)

if [[ ${#tests[@]} -eq 0 ]]; then
  ok "no *.test.ts files"
  echo "all pi-extensions checks passed"
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  ok "extension tests skipped (node not installed)"
  echo "all pi-extensions checks passed"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home" "$work/cache" "$work/pi-agent"

# Does this Node load TypeScript, with or without the opt-in flag?
printf 'const x: number = 1;\nif (x !== 1) process.exit(1);\n' > "$work/probe.ts"
strip_flag=()
if node "$work/probe.ts" >/dev/null 2>&1; then
  :
elif node --experimental-strip-types "$work/probe.ts" >/dev/null 2>&1; then
  strip_flag=(--experimental-strip-types)
else
  ok "extension tests skipped (node cannot strip TypeScript types)"
  echo "all pi-extensions checks passed"
  exit 0
fi

out="$work/node-test.out"
if HOME="$work/home" XDG_CACHE_HOME="$work/cache" PI_CODING_AGENT_DIR="$work/pi-agent" \
    PI_NOGG_USAGE_PROBE=0 \
    node ${strip_flag[@]+"${strip_flag[@]}"} --test "${tests[@]}" >"$out" 2>&1; then
  ok "extension tests (${#tests[@]} file(s))"
else
  cat "$out"
  fail "extension tests failed"
  exit 1
fi

echo "all pi-extensions checks passed"
