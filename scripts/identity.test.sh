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

grep -q 'Display name: \*\*SpecForge\*\*' "$identity" || fail "SpecForge is not canonical"
grep -q 'Agentsembli is a provisional working name' "$identity" || fail "Agentsembli is not qualified as provisional"
grep -q 'SpecForge works without Agent Console' "$identity" || fail "Agent Console is not optional"
grep -q 'github.com/JoMe92/specforge' "$identity" || fail "repository destination is missing"
grep -q 'github.com/JoMe92/specforge/issues' "$identity" || fail "support destination is missing"
grep -q 'github.com/JoMe92/specforge/security' "$identity" || fail "security destination is missing"
grep -q 'github.com/steveyegge/gastown' "$identity" || fail "Gas Town link is missing"
grep -q 'github.com/gastownhall/beads' "$identity" || fail "Beads link is missing"
grep -q 'only component' "$identity" || fail "Beads-only adoption boundary is missing"
grep -q 'independent implementation' "$identity" || fail "independent implementation statement is missing"
grep -q 'not affiliated with or' "$identity" || fail "non-affiliation statement is missing"
grep -q 'a local-first delivery system that carries approved intent' "$identity" || fail "concept statement is missing"
grep -q '## Technical identifier inventory' "$identity" || fail "technical identifier inventory is missing"
grep -q 'require no' "$identity" || fail "no-migration lifecycle decision is missing"

# Technical identity surfaces must retain the established SpecForge identifiers.
# Agentsembli is ecosystem language only and must never become an installed name.
technical_surfaces=(
  package.json
  bin
  scripts
  templates
  .specforge/launch-profiles
  .specforge/launch-prompts
  .codex
  .pi
)
if grep -Rni --exclude='identity.test.sh' 'agentsembli' "${technical_surfaces[@]}"; then
  fail "provisional ecosystem name leaked into a technical identity surface"
fi

grep -q 'npx github:JoMe92/specforge' bin/cli.js || fail "CLI install command changed identity"
grep -q "'scripts/specforge'" bin/lib/manifest.js || fail "installed command path changed identity"
grep -q "to: 'docs/specforge/" bin/lib/manifest.js || fail "installed documentation path changed identity"
grep -q 'specforge-sync-{slug}' bin/lib/manifest.js || fail "generated sync unit changed identity"
grep -q 'specforge-orchestrator-{slug}' bin/lib/manifest.js || fail "generated orchestrator unit changed identity"
grep -q '"name": "SpecForge"' templates/specforge-config.json || fail "generated config changed identity"
grep -q 'scfg("session_tmux_socket", "specforge")' scripts/specforge || fail "tmux socket changed identity"

node -e '
  const pkg = require("./package.json");
  if (pkg.name !== "specforge") throw new Error(`unexpected package name: ${pkg.name}`);
  if (pkg.bin?.specforge !== "bin/cli.js") throw new Error("specforge CLI entry is missing");
  if (pkg.private === false) throw new Error("package explicitly enables publication");
' || fail "package identity contradicts the canonical document"

printf 'project identity: ok\n'
