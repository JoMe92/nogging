#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
doc="$root/docs/compatibility.md"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

for required in Node.js Python Git 'GNU Bash' 'OpenSpec CLI' 'Beads (`bd`)' \
  Dolt tmux systemd x86_64 aarch64 macOS Windows 'Claude Code' \
  'OpenAI Codex CLI' 'Pi coding agent'; do
  grep -Fq "$required" "$doc" || fail "compatibility matrix omits $required"
done

node - "$root/package.json" <<'NODE'
const pkg = require(process.argv[2]);
if (pkg.engines?.node !== '>=18') throw new Error('Node engine differs from compatibility baseline');
if (!pkg.files.includes('docs/compatibility.md')) throw new Error('compatibility guide is not packaged');
NODE

grep -Fq "docs/compatibility.md" "$root/bin/lib/manifest.js" \
  || fail "compatibility guide is not installed"
grep -Fq "compatibility baseline: Node 18/20/22, Python 3.9-3.13" "$root/scripts/nogg" \
  || fail "doctor does not expose the documented baseline"
for version in 18 20 22; do
  grep -Eq "node: \[18, 20, 22\]" "$root/.github/workflows/nogging-validate.yml" \
    || fail "CI does not cover supported Node versions"
done
grep -Eq "python: \['3.9', '3.11', '3.13'\]" "$root/.github/workflows/nogging-validate.yml" \
  || fail "CI does not cover supported Python versions"

# --- scripts/bootstrap pin consistency --------------------------------------
# scripts/bootstrap hardcodes its own version pins (Decision 5, design.md):
# this parses both that script's pins and this document's validated-version
# table and fails if either drifts from the other, so a version bump that
# updates one without the other is caught here, not discovered later by a
# user getting an unvalidated combination.
bootstrap="$root/scripts/bootstrap"
test -f "$bootstrap" || fail "scripts/bootstrap is missing"

bootstrap_pin() {
  grep -E "^$1=" "$bootstrap" | head -n1 | sed -E 's/^[A-Za-z_]+="([^"]*)".*/\1/'
}
doc_validated() {
  # doc_validated <row-label-substring> -> the "validated with X.Y.Z" version
  # on that compatibility-matrix row.
  grep -F "$1" "$doc" | grep -Eo 'validated with [0-9]+\.[0-9]+\.[0-9]+' \
    | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}
check_pin() {
  var="$1"; expected="$2"; label="$3"
  got=$(bootstrap_pin "$var")
  [ -n "$got" ] || fail "scripts/bootstrap has no $var pin"
  [ -n "$expected" ] || fail "docs/compatibility.md has no validated version for $label"
  [ "$got" = "$expected" ] \
    || fail "scripts/bootstrap's $var ($got) disagrees with docs/compatibility.md's $label validated version ($expected)"
}

check_pin CLAUDE_CODE_VERSION "$(doc_validated 'Claude Code')" "Claude Code"
check_pin CODEX_VERSION "$(doc_validated 'OpenAI Codex CLI')" "OpenAI Codex CLI"
check_pin OPENSPEC_VERSION "$(doc_validated 'OpenSpec CLI')" "OpenSpec CLI"
check_pin PI_VERSION "$(doc_validated 'Pi coding agent')" "Pi coding agent"
check_pin BD_VERSION "$(doc_validated 'Beads (`bd`)')" "Beads"
check_pin DOLT_VERSION "$(doc_validated 'Dolt')" "Dolt"

node_line=$(grep -F 'Node.js' "$doc" | grep -Eo '[0-9]+, [0-9]+, and [0-9]+ LTS' | head -n1)
[ -n "$node_line" ] || fail "docs/compatibility.md has no Node LTS line triple"
doc_node_set=$(printf '%s' "$node_line" | grep -Eo '[0-9]+' | tr '\n' ' ' | sed -E 's/ $//')
bootstrap_node_set=$(bootstrap_pin NODE_LTS_LINE)
[ "$bootstrap_node_set" = "$doc_node_set" ] \
  || fail "scripts/bootstrap's NODE_LTS_LINE ($bootstrap_node_set) disagrees with docs/compatibility.md's Node LTS line ($doc_node_set)"
bootstrap_node_pin=$(bootstrap_pin NODE_LTS_PIN)
case " $doc_node_set " in
  *" $bootstrap_node_pin "*) : ;;
  *) fail "scripts/bootstrap's NODE_LTS_PIN ($bootstrap_node_pin) is not one of docs/compatibility.md's supported Node LTS lines ($doc_node_set)" ;;
esac

pkg_version=$(node -p "require('$root/package.json').version")
bootstrap_tag=$(bootstrap_pin NOGGING_TAG)
[ "$bootstrap_tag" = "v$pkg_version" ] \
  || fail "scripts/bootstrap's NOGGING_TAG ($bootstrap_tag) disagrees with package.json's version (v$pkg_version)"

printf 'scripts/bootstrap pin consistency: ok\n'
printf 'compatibility policy and matrix: ok\n'
