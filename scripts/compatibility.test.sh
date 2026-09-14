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

printf 'compatibility policy and matrix: ok\n'
