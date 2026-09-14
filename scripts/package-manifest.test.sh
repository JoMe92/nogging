#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
snapshot="$(mktemp -d)"
pack_json="$(mktemp)"
trap 'rm -rf "$snapshot"; rm -f "$pack_json"' EXIT

# checkout-index produces a detached, clean tree from exactly the content that
# would be committed. CI exercises HEAD; maintainers can stage a proposed
# manifest and get the same clean-tree package inspection before committing.
git -C "$root" checkout-index --all --prefix="$snapshot/"
cd "$snapshot"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

node <<'NODE'
const pkg = require('./package.json');
const broad = new Set(['bin', 'docs', 'scripts', 'templates', '.agents']);
for (const entry of pkg.files) {
  if (broad.has(entry) || entry.startsWith('!')) {
    throw new Error(`package files must be an explicit allowlist, found ${entry}`);
  }
}
NODE

npm pack --dry-run --json >"$pack_json"

node - "$pack_json" <<'NODE'
const fs = require('fs');
const manifest = require('./bin/lib/manifest');
const report = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'))[0];
const packed = new Set(report.files.map(file => file.path));

const required = [
  'package.json', 'LICENSE', 'README.md', 'SECURITY.md',
  'THIRD_PARTY_NOTICES.md', 'AGENTS.md', 'bin/cli.js',
  'docs/installation.md', 'docs/security-model.md', 'docs/using-with-pi.md',
  'openspec/config.yaml',
  ...manifest.verbatim,
  ...manifest.scaffold.map(item => item.from),
  ...manifest.docs.map(item => item.from),
  ...manifest.systemd.map(item => item.from),
];

for (const dir of manifest.verbatimDirs) {
  const walk = path => {
    for (const entry of fs.readdirSync(path, {withFileTypes: true})) {
      const child = `${path}/${entry.name}`;
      if (entry.isDirectory()) walk(child);
      else required.push(child);
    }
  };
  walk(dir.from);
}

const missing = [...new Set(required)].filter(path => !packed.has(path));
if (missing.length) {
  console.error(missing.join('\n'));
  throw new Error('required runtime or user-documentation payload is absent');
}

const forbidden = [...packed].filter(path =>
  path.startsWith('docs/source/') ||
  path.startsWith('docs/acceptance/') ||
  path.startsWith('docs/product-identity/') ||
  path.startsWith('docs/security/') ||
  path.startsWith('systemd/') ||
  path.startsWith('.github/') ||
  path.startsWith('.beads/') ||
  path.startsWith('.nogging/state/') ||
  path.startsWith('openspec/changes/') ||
  path.includes('__pycache__/') ||
  /\.py[co]$/.test(path)
);
if (forbidden.length) {
  console.error(forbidden.join('\n'));
  throw new Error('package contains internal, generated, cached, or acceptance data');
}
NODE

printf 'clean package manifest: ok\n'
