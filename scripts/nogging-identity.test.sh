#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

identity=docs/project-identity.md
test -f "$identity" || fail "canonical project identity document is missing"

grep -q 'Display name: \*\*Nogging\*\*' "$identity" || fail "Nogging is not canonical"
grep -q 'Nogging works without Agent Console' "$identity" || fail "Agent Console is not optional"
grep -q 'github.com/JoMe92/nogging' "$identity" || fail "repository destination is missing"
grep -q 'github.com/JoMe92/nogging/issues' "$identity" || fail "support destination is missing"
grep -q 'github.com/JoMe92/nogging/security' "$identity" || fail "security destination is missing"
grep -q 'github.com/steveyegge/gastown' "$identity" || fail "Gas Town link is missing"
grep -q 'github.com/gastownhall/beads' "$identity" || fail "Beads link is missing"
grep -q 'only component' "$identity" || fail "Beads-only adoption boundary is missing"
grep -q 'independent implementation' "$identity" || fail "independent implementation statement is missing"
grep -q 'not affiliated with or' "$identity" || fail "non-affiliation statement is missing"
grep -q 'a local-first delivery system that carries approved intent' "$identity" || fail "concept statement is missing"
grep -q '## Technical identifier inventory' "$identity" || fail "technical identifier inventory is missing"
grep -q 'require no' "$identity" || fail "no-migration lifecycle decision is missing"

# The legacy URL is provenance only. Its one maintained occurrence is the
# migration/rollback record; all active destinations must use the successor.
legacy_repo="JoMe92/spec""forge"
legacy_hits=$(git grep -l "$legacy_repo" -- ':!openspec/**' ':!scripts/nogging-identity.test.sh' || true)
test "$legacy_hits" = "docs/security/successor-migration-2026-09-10.md" \
  || fail "legacy repository URL escaped its transition-document allowlist"

grep -q 'npx github:JoMe92/nogging' bin/cli.js || fail "CLI install command changed identity"
grep -q "'scripts/nogg'" bin/lib/manifest.js || fail "installed command path changed identity"
grep -q "to: 'docs/nogging/" bin/lib/manifest.js || fail "installed documentation path changed identity"
grep -q 'nogg-sync-{slug}' bin/lib/manifest.js || fail "generated sync unit changed identity"
grep -q 'nogg-orchestrator-{slug}' bin/lib/manifest.js || fail "generated orchestrator unit changed identity"
grep -q '"name": "Nogging"' templates/nogging-config.json || fail "generated config changed identity"
grep -q 'scfg("session_tmux_socket", "nogging")' scripts/nogg || fail "tmux socket changed identity"
grep -q '^# Nogging$' README.md || fail "README display name is stale"
grep -q '^## Project status and audience$' README.md || fail "README maturity and audience section is missing"
grep -q 'pre-public release candidate' README.md || fail "README maturity status is missing"
grep -q '^## Supported environments$' README.md || fail "README support summary is missing"
grep -q '^## Safety warning$' README.md || fail "README safety warning is missing"
grep -q '^## Documentation$' README.md || fail "README documentation index is missing"
grep -q '^## Inspiration and related projects$' README.md || fail "README provenance section is missing"
grep -q 'github.com/steveyegge/gastown' README.md || fail "README Gas Town link is missing"
grep -q 'github.com/gastownhall/beads' README.md || fail "README Beads link is missing"
grep -q 'independent$' README.md && grep -q '^implementation and is not affiliated' README.md \
  || fail "README independence statement is missing"
grep -q 'only Gas Town' README.md || fail "README Beads-only adoption boundary is missing"
grep -q 'optional sibling' README.md || fail "README does not keep Agent Console optional"
grep -q 'npx github:JoMe92/nogging#v1.6.0 init --no-systemd' README.md \
  || fail "README quick start is not pinned to the supported GitHub tag"
! grep -q 'git@github.com' README.md || fail "README assumes private SSH repository access"
grep -q 'Nogging validation' .github/workflows/nogging-validate.yml || fail "workflow display name is stale"
grep -q 'security/advisories/new' SECURITY.md || fail "security reporting route is missing"

node <<'NODE' || fail "README contains a missing relative link"
const fs = require('fs');
const path = require('path');
const text = fs.readFileSync('README.md', 'utf8');
for (const match of text.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)) {
  const target = match[1].split('#', 1)[0];
  if (!target || /^[a-z]+:/i.test(target)) continue;
  if (!fs.existsSync(path.resolve(target))) {
    throw new Error(`missing README link target: ${target}`);
  }
}
NODE

node -e '
  const pkg = require("./package.json");
  if (pkg.name !== "nogg") throw new Error(`unexpected package name: ${pkg.name}`);
  if (pkg.bin?.nogg !== "bin/cli.js") throw new Error("nogg CLI entry is missing");
  if (pkg.private === false) throw new Error("package explicitly enables publication");
' || fail "package identity contradicts the canonical document"

printf 'project identity: ok\n'
