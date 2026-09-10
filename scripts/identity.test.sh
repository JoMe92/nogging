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

grep -q 'Display name: \*\*Agentsembli SpecForge\*\*' "$identity" || fail "Agentsembli SpecForge is not canonical"
grep -q 'does not introduce a separate runtime' "$identity" || fail "Agentsembli runtime boundary is missing"
grep -q 'SpecForge works without Agent Console' "$identity" || fail "Agent Console is not optional"
grep -q 'github.com/JoMe92/agentsembli-specforge' "$identity" || fail "repository destination is missing"
grep -q 'github.com/JoMe92/agentsembli-specforge/issues' "$identity" || fail "support destination is missing"
grep -q 'github.com/JoMe92/agentsembli-specforge/security' "$identity" || fail "security destination is missing"
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
legacy_hits=$(git grep -l 'JoMe92/specforge' -- ':!openspec/**' ':!scripts/identity.test.sh' || true)
test "$legacy_hits" = 'docs/security/successor-migration-2026-09-10.md' \
  || fail "legacy repository URL escaped its transition-document allowlist"

grep -q 'npx github:JoMe92/agentsembli-specforge' bin/cli.js || fail "CLI install command changed identity"
grep -q "'scripts/specforge'" bin/lib/manifest.js || fail "installed command path changed identity"
grep -q "to: 'docs/specforge/" bin/lib/manifest.js || fail "installed documentation path changed identity"
grep -q 'specforge-sync-{slug}' bin/lib/manifest.js || fail "generated sync unit changed identity"
grep -q 'specforge-orchestrator-{slug}' bin/lib/manifest.js || fail "generated orchestrator unit changed identity"
grep -q '"name": "SpecForge"' templates/specforge-config.json || fail "generated config changed identity"
grep -q 'scfg("session_tmux_socket", "specforge")' scripts/specforge || fail "tmux socket changed identity"
grep -q '^# Agentsembli SpecForge$' README.md || fail "README display name is stale"
grep -q 'Agentsembli SpecForge validation' .github/workflows/specforge-validate.yml || fail "workflow display name is stale"
grep -q 'security/advisories/new' SECURITY.md || fail "security reporting route is missing"

node -e '
  const pkg = require("./package.json");
  if (pkg.name !== "specforge") throw new Error(`unexpected package name: ${pkg.name}`);
  if (pkg.bin?.specforge !== "bin/cli.js") throw new Error("specforge CLI entry is missing");
  if (pkg.private === false) throw new Error("package explicitly enables publication");
' || fail "package identity contradicts the canonical document"

printf 'project identity: ok\n'
