#!/usr/bin/env bash
# Legacy (un-manifested) upgrades and the --force CLI option (TASK-PVE-003).
# Offline: synthetic baselines are injected in-process, no network, no tmux.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if ! command -v node >/dev/null 2>&1; then
  echo 'ok   - skipped (node not installed)'
  exit 0
fi

node - "$root" <<'NODE'
'use strict';
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const root = process.argv[2];
const store = require(path.join(root, 'bin/lib/manifest-store'));
const baselines = require(path.join(root, 'bin/lib/baselines'));
const install = require(path.join(root, 'bin/lib/install'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'nogging-legacy-upgrade-'));
let count = 0;

function check(name, fn) {
  fn();
  console.log(`ok   - ${name}`);
}

function runInstall(targetRoot, opts = {}) {
  const ctx = install.makeContext({ targetRoot, ...opts });
  install.copyVerbatim(ctx);
  install.copyDocs(ctx);
  install.recordVersion(ctx);
  return ctx;
}

// A fresh install whose manifest is removed, i.e. what a pre-manifest release left.
function legacyRepo(version) {
  const targetRoot = path.join(work, String(++count));
  fs.mkdirSync(path.join(targetRoot, '.git'), { recursive: true });
  runInstall(targetRoot);
  fs.writeFileSync(path.join(targetRoot, '.nogging/config.json'),
    JSON.stringify({ name: 'legacy', nogging_version: version }) + '\n');
  fs.unlinkSync(path.join(targetRoot, store.MANIFEST_REL_PATH));
  return targetRoot;
}

const rules = '.codex/rules/nogging.rules';
const prompt = '.nogging/launch-prompts/orchestrator.md';
const tool = 'scripts/nogg';
const upstream = (rel) => store.hashFile(path.join(root, rel));
const entry = (ctx, rel) => ctx.log.entries.find((e) => e.path === rel);

try {
  check('bundled releases 2.1.0 and 2.2.0 are available as baselines', () => {
    for (const v of ['2.1.0', '2.2.0', 'v2.2.0']) assert.ok(baselines.getBaseline(v), v);
  });

  // Synthetic releases: file contents the package never ships, hashed as baselines.
  baselines.BASELINES['9.0.0-test'] = {
    [rules]: store.sha256('old rules\n'), [tool]: store.sha256('old nogg\n'),
    [prompt]: store.sha256('old prompt\n'),
  };
  baselines.BASELINES['9.0.1-test'] = { [prompt]: store.sha256('other release prompt\n') };

  check('unmodified files of the recorded legacy release update cleanly with no warnings', () => {
    const t = legacyRepo('9.0.0-test');
    fs.writeFileSync(path.join(t, rules), 'old rules\n');
    fs.writeFileSync(path.join(t, tool), 'old nogg\n');
    const ctx = runInstall(t);
    assert.strictEqual(entry(ctx, rules).action, 'update');
    assert.strictEqual(entry(ctx, tool).action, 'update');
    assert.deepStrictEqual(ctx.warnings, []);
    assert.strictEqual(fs.existsSync(path.join(t, `${rules}.nogging-new`)), false);
    assert.strictEqual(store.hashFile(path.join(t, rules)), upstream(rules));
  });

  check('a legacy version prefixed with v resolves its baseline', () => {
    const t = legacyRepo('v9.0.0-test');
    fs.writeFileSync(path.join(t, rules), 'old rules\n');
    assert.strictEqual(entry(runInstall(t), rules).action, 'update');
  });

  check('unknown or missing recorded version still accepts a file matching any bundled release', () => {
    for (const version of ['0.0.0-unknown', null]) {
      const t = legacyRepo(version);
      fs.writeFileSync(path.join(t, prompt), 'other release prompt\n');
      const ctx = runInstall(t);
      assert.strictEqual(entry(ctx, prompt).action, 'update');
      assert.deepStrictEqual(ctx.warnings, []);
    }
  });

  check('locally modified legacy file is preserved with a .nogging-new sibling', () => {
    const t = legacyRepo('9.0.0-test');
    fs.writeFileSync(path.join(t, rules), 'old rules\n# my local tweak\n');
    fs.writeFileSync(path.join(t, tool), 'old nogg\n');
    const ctx = runInstall(t);
    assert.strictEqual(entry(ctx, rules).action, 'preserve');
    assert.strictEqual(fs.readFileSync(path.join(t, rules), 'utf8'), 'old rules\n# my local tweak\n');
    assert.strictEqual(store.hashFile(path.join(t, `${rules}.nogging-new`)), upstream(rules));
    assert.strictEqual(entry(ctx, tool).action, 'update');
    assert.deepStrictEqual(ctx.review, [{ kind: 'preserve', path: rules }]);
    assert.deepStrictEqual(ctx.warnings, []);
  });

  check('a file matching no baseline is preserved conservatively and never recorded', () => {
    const t = legacyRepo('0.0.0-unknown');
    fs.writeFileSync(path.join(t, prompt), 'mystery local content\n');
    const ctx = runInstall(t);
    assert.strictEqual(entry(ctx, prompt).action, 'preserve');
    assert.strictEqual(fs.readFileSync(path.join(t, prompt), 'utf8'), 'mystery local content\n');
    assert.strictEqual(store.readManifest(t).files[prompt], undefined);
  });

  check('the manifest is written after a legacy upgrade', () => {
    const t = legacyRepo('9.0.0-test');
    fs.writeFileSync(path.join(t, rules), 'old rules\n');
    runInstall(t);
    const m = store.readManifest(t);
    assert.strictEqual(m.nogging_version, install.packageVersion());
    assert.strictEqual(m.files[rules], upstream(rules));
    assert.strictEqual(JSON.parse(fs.readFileSync(path.join(t, '.nogging/config.json'), 'utf8')).nogging_version,
      install.packageVersion());
  });

  check('legacy dry-run reports the outcome and writes nothing, not even a manifest', () => {
    const t = legacyRepo('9.0.0-test');
    fs.writeFileSync(path.join(t, rules), 'old rules\n# local\n');
    fs.writeFileSync(path.join(t, tool), 'old nogg\n');
    const ctx = runInstall(t, { dryRun: true });
    assert.strictEqual(entry(ctx, rules).action, 'preserve');
    assert.strictEqual(entry(ctx, tool).action, 'update');
    assert.strictEqual(fs.existsSync(path.join(t, `${rules}.nogging-new`)), false);
    assert.strictEqual(fs.readFileSync(path.join(t, tool), 'utf8'), 'old nogg\n');
    assert.strictEqual(store.readManifest(t), null);
  });

  check('an existing manifest outranks the legacy baselines', () => {
    const t = legacyRepo('9.0.0-test');
    fs.writeFileSync(path.join(t, rules), 'old rules\n');
    store.writeManifest(t, { manifest_version: 1, nogging_version: '9.0.0-test', files: { [rules]: store.sha256('something else') } });
    assert.strictEqual(entry(runInstall(t), rules).action, 'preserve');
  });

  // --- CLI: --force, usage and report --------------------------------------
  const cli = path.join(root, 'bin/cli.js');
  function nogg(cwd, ...args) {
    const r = spawnSync('node', [cli, ...args], { cwd, encoding: 'utf8' });
    return { status: r.status, out: `${r.stdout}${r.stderr}` };
  }
  // The CLI runs `scripts/nogg doctor` after a real install; stub it so the
  // test stays fast and independent of the host (git, tmux, Beads).
  const repo = legacyRepo('0.0.0-unknown');
  fs.writeFileSync(path.join(repo, tool), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  fs.writeFileSync(path.join(repo, rules), 'local rules\n');
  const flags = ['--no-beads', '--no-hooks', '--no-systemd'];

  check('usage documents --force', () => {
    const r = nogg(repo, '--help');
    assert.match(r.out, /--force\s+Overwrite locally modified verbatim files/);
    assert.match(r.out, /<file>\.orig/);
  });
  check('--force is rejected for commands it does not apply to', () => {
    const r = nogg(repo, 'remove', '--force');
    assert.strictEqual(r.status, 2);
    assert.match(r.out, /--force only applies to init and update/);
  });
  check('update without a manifest preserves the edit and reports where upstream lives', () => {
    const r = nogg(repo, 'update', ...flags);
    assert.strictEqual(r.status, 0, r.out);
    assert.strictEqual(fs.readFileSync(path.join(repo, rules), 'utf8'), 'local rules\n');
    assert.match(r.out, /Needs your review/);
    assert.match(r.out, /\.codex\/rules\/nogging\.rules — kept your edit; upstream in \.codex\/rules\/nogging\.rules\.nogging-new/);
    assert.match(r.out, /--force/);
    assert.ok(fs.existsSync(path.join(repo, store.MANIFEST_REL_PATH)));
  });
  check('update --dry-run --force names the backup and writes nothing', () => {
    const r = nogg(repo, 'update', '--dry-run', '--force', ...flags);
    assert.match(r.out, /would be overwritten \(--force\)/);
    assert.match(r.out, /backup would go to \.codex\/rules\/nogging\.rules\.orig/);
    assert.strictEqual(fs.existsSync(path.join(repo, `${rules}.orig`)), false);
    assert.strictEqual(fs.readFileSync(path.join(repo, rules), 'utf8'), 'local rules\n');
  });
  check('update --force backs up to .orig and installs upstream', () => {
    const ctx = runInstall(repo, { force: true });
    assert.strictEqual(fs.readFileSync(path.join(repo, `${rules}.orig`), 'utf8'), 'local rules\n');
    assert.strictEqual(store.hashFile(path.join(repo, rules)), upstream(rules));
    assert.deepStrictEqual(ctx.review.filter((r) => r.path === rules), [{ kind: 'force', path: rules }]);
    assert.strictEqual(entry(ctx, rules).action, 'force-overwrite');
  });
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
console.log('Nogging: all manifest-legacy-upgrade checks passed');
NODE
