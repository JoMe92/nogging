#!/usr/bin/env bash
# Three-way copying and installed-manifest integration (TASK-PVE-002).
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
const root = process.argv[2];
const store = require(path.join(root, 'bin/lib/manifest-store'));
const fsops = require(path.join(root, 'bin/lib/fsops'));
const install = require(path.join(root, 'bin/lib/install'));
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'nogging-manifest-update-'));
let count = 0;

function check(name, fn) {
  fn();
  console.log(`ok   - ${name}`);
}

function fixture({ current, recorded, next = 'upstream\n', dryRun = false, force = false, mode } = {}) {
  const targetRoot = path.join(work, String(++count));
  fs.mkdirSync(targetRoot);
  const rel = 'scripts/tool';
  const dest = path.join(targetRoot, rel);
  const source = path.join(targetRoot, 'source');
  fs.writeFileSync(source, next);
  if (current != null) {
    fs.mkdirSync(path.dirname(dest));
    fs.writeFileSync(dest, current, { mode: 0o600 });
  }
  const installedManifest = {
    manifest_version: 1, nogging_version: 'old',
    files: recorded == null ? {} : { [rel]: store.sha256(recorded) },
  };
  const ctx = {
    targetRoot, dryRun, force, installedManifest, warnings: [], log: new fsops.ChangeLog(),
    nextInstalledManifest: { ...installedManifest, files: { ...installedManifest.files } },
  };
  return { ctx, dest, rel, run: () => fsops.copyFile(source, rel, ctx, { mode }) };
}

function snapshot(dir) {
  const files = {};
  function walk(abs, rel = '') {
    for (const ent of fs.readdirSync(abs, { withFileTypes: true })) {
      const child = path.join(abs, ent.name);
      const key = path.posix.join(rel, ent.name);
      if (ent.isDirectory()) walk(child, key);
      else files[key] = { bytes: fs.readFileSync(child).toString('hex'), mode: fs.statSync(child).mode };
    }
  }
  walk(dir);
  return files;
}

try {
  check('missing file is created and its upstream digest recorded', () => {
    const f = fixture({ mode: 0o755 });
    assert.strictEqual(f.run(), 'create');
    assert.strictEqual(fs.readFileSync(f.dest, 'utf8'), 'upstream\n');
    assert.strictEqual(fs.statSync(f.dest).mode & 0o777, 0o755);
    assert.strictEqual(f.ctx.nextInstalledManifest.files[f.rel], store.sha256('upstream\n'));
  });

  check('identical content stays untouched and becomes the accepted baseline', () => {
    const f = fixture({ current: 'upstream\n', recorded: 'older', mode: 0o755 });
    const before = fs.statSync(f.dest);
    assert.strictEqual(f.run(), 'unchanged');
    const after = fs.statSync(f.dest);
    assert.strictEqual(after.mtimeMs, before.mtimeMs);
    assert.strictEqual(after.ctimeMs, before.ctimeMs);
    assert.strictEqual(f.ctx.nextInstalledManifest.files[f.rel], store.sha256('upstream\n'));
  });

  check('clean upstream change updates the destination and baseline', () => {
    const f = fixture({ current: 'previous', recorded: 'previous' });
    assert.strictEqual(f.run(), 'update');
    assert.strictEqual(fs.readFileSync(f.dest, 'utf8'), 'upstream\n');
    assert.strictEqual(f.ctx.nextInstalledManifest.files[f.rel], store.sha256('upstream\n'));
    assert.deepStrictEqual(f.ctx.warnings, []);
  });

  check('local edit is preserved with a warning, sidecar, and old baseline', () => {
    const f = fixture({ current: 'local edit', recorded: 'previous', mode: 0o755 });
    const before = fs.statSync(f.dest);
    assert.strictEqual(f.run(), 'preserve');
    assert.strictEqual(fs.readFileSync(f.dest, 'utf8'), 'local edit');
    assert.strictEqual(fs.statSync(f.dest).ctimeMs, before.ctimeMs);
    assert.strictEqual(fs.readFileSync(`${f.dest}.nogging-new`, 'utf8'), 'upstream\n');
    assert.strictEqual(fs.statSync(`${f.dest}.nogging-new`).mode & 0o777, 0o755);
    assert.strictEqual(f.ctx.nextInstalledManifest.files[f.rel], store.sha256('previous'));
    assert.deepStrictEqual(f.ctx.review, [{ kind: 'preserve', path: f.rel }]);
    assert.deepStrictEqual(f.ctx.warnings, []);
    assert.match(f.ctx.log.render(), /preserve.*scripts\/tool.nogging-new/);
  });

  check('unknown baseline never records a local edit or pending upstream as accepted', () => {
    const f = fixture({ current: 'local edit' });
    assert.strictEqual(f.run(), 'preserve');
    assert.strictEqual(f.ctx.nextInstalledManifest.files[f.rel], undefined);
  });

  check('force saves local bytes as .orig before accepting the upstream replacement', () => {
    const f = fixture({ current: 'local edit', recorded: 'previous', force: true, mode: 0o755 });
    assert.strictEqual(f.run(), 'force-overwrite');
    assert.strictEqual(fs.readFileSync(`${f.dest}.orig`, 'utf8'), 'local edit');
    assert.strictEqual(fs.readFileSync(f.dest, 'utf8'), 'upstream\n');
    assert.strictEqual(f.ctx.nextInstalledManifest.files[f.rel], store.sha256('upstream\n'));
    assert.deepStrictEqual(f.ctx.review, [{ kind: 'force', path: f.rel }]);
    assert.deepStrictEqual(f.ctx.warnings, []);
    assert.match(f.ctx.log.render(), /force-overwrite.*backup: scripts\/tool.orig/);
  });

  check('a failed force backup leaves the local destination and baseline intact', () => {
    const f = fixture({ current: 'local edit', recorded: 'previous', force: true });
    fs.mkdirSync(`${f.dest}.orig`);
    assert.throws(f.run);
    assert.strictEqual(fs.readFileSync(f.dest, 'utf8'), 'local edit');
    assert.strictEqual(f.ctx.nextInstalledManifest.files[f.rel], store.sha256('previous'));
  });

  check('dry-run reports every state and leaves destinations and sidecars untouched', () => {
    for (const [current, recorded, expected, force] of [
      [undefined, undefined, 'create'], ['upstream\n', 'old', 'unchanged'],
      ['old', 'old', 'update'], ['local', 'old', 'preserve'],
      ['local', 'old', 'force-overwrite', true],
    ]) {
      const f = fixture({ current, recorded, force, dryRun: true, mode: 0o755 });
      fs.mkdirSync(path.dirname(f.dest), { recursive: true });
      fs.writeFileSync(`${f.dest}.nogging-new`, 'pending older upstream');
      fs.writeFileSync(`${f.dest}.orig`, 'existing backup');
      const before = snapshot(f.ctx.targetRoot);
      assert.strictEqual(f.run(), expected);
      assert.deepStrictEqual(snapshot(f.ctx.targetRoot), before);
      assert.match(f.ctx.log.render(), new RegExp(expected));
    }
  });

  const targetRoot = path.join(work, 'installed');
  fs.mkdirSync(path.join(targetRoot, '.git'), { recursive: true });
  function runInstall(opts = {}) {
    const ctx = install.makeContext({ targetRoot, ...opts });
    install.copyVerbatim(ctx);
    install.copyDocs(ctx);
    install.recordVersion(ctx);
    return ctx;
  }
  check('fresh install dry-run creates no directories, files, or manifest', () => {
    const before = snapshot(targetRoot);
    const ctx = runInstall({ dryRun: true });
    assert.deepStrictEqual(snapshot(targetRoot), before);
    assert.strictEqual(store.readManifest(targetRoot), null);
    assert.ok(ctx.log.entries.some(e => e.path === store.MANIFEST_REL_PATH && e.action === 'create'));
  });
  check('fresh installation records every verbatim, recursive, and documentation file', () => {
    runInstall();
    assert.deepStrictEqual(store.readManifest(targetRoot), store.computePackageManifest(root, install.packageVersion()));
  });
  check('recordVersion writes the manifest even when the configured version is current', () => {
    const config = path.join(targetRoot, '.nogging/config.json');
    const content = JSON.stringify({ name: 'custom project', nogging_version: install.packageVersion() }) + '\n';
    fs.writeFileSync(config, content);
    const before = fs.statSync(config);
    fs.unlinkSync(path.join(targetRoot, store.MANIFEST_REL_PATH));
    runInstall();
    assert.deepStrictEqual(store.readManifest(targetRoot), store.computePackageManifest(root, install.packageVersion()));
    assert.strictEqual(fs.readFileSync(config, 'utf8'), content);
    assert.strictEqual(fs.statSync(config).ctimeMs, before.ctimeMs);
  });
  check('idempotent re-install leaves all managed content and manifest identical', () => {
    const before = snapshot(targetRoot);
    const ctx = runInstall();
    assert.deepStrictEqual(snapshot(targetRoot), before);
    assert.strictEqual(ctx.log.touched().length, 0);
  });

  const modified = ['scripts/nogg', '.codex/rules/nogging.rules',
    '.nogging/launch-prompts/orchestrator.md', 'docs/nogging/operating-model.md'];
  const accepted = store.readManifest(targetRoot);
  for (const rel of modified) fs.appendFileSync(path.join(targetRoot, rel), '\nlocal customization\n');
  check('installer dry-run preserves the entire tree and manifest while reporting conflicts', () => {
    const before = snapshot(targetRoot);
    const ctx = runInstall({ dryRun: true });
    assert.deepStrictEqual(snapshot(targetRoot), before);
    assert.strictEqual(ctx.log.entries.filter(e => e.action === 'preserve').length, modified.length);
    assert.strictEqual(ctx.review.filter(r => r.kind === 'preserve').length, modified.length);
    assert.deepStrictEqual(ctx.warnings, []);
  });
  check('successive updates preserve edits across every managed file class', () => {
    for (let pass = 0; pass < 2; pass++) {
      const ctx = runInstall();
      assert.strictEqual(ctx.review.length, modified.length);
      for (const rel of modified) {
        assert.match(fs.readFileSync(path.join(targetRoot, rel), 'utf8'), /local customization/);
        assert.strictEqual(store.hashFile(path.join(targetRoot, `${rel}.nogging-new`)), accepted.files[rel]);
      }
      assert.deepStrictEqual(store.readManifest(targetRoot), accepted);
    }
  });
  check('installer force context backs up customized files across every managed file class', () => {
    const ctx = runInstall({ force: true });
    assert.strictEqual(ctx.review.length, modified.length);
    for (const rel of modified) {
      assert.match(fs.readFileSync(path.join(targetRoot, `${rel}.orig`), 'utf8'), /local customization/);
      assert.strictEqual(store.hashFile(path.join(targetRoot, rel)), accepted.files[rel]);
    }
    assert.deepStrictEqual(store.readManifest(targetRoot), accepted);
  });
  check('reverting to the accepted baseline permits a later clean upstream update', () => {
    const rel = '.codex/rules/nogging.rules';
    const dest = path.join(targetRoot, rel);
    fs.copyFileSync(`${dest}.nogging-new`, dest);
    const pkgRoot = path.join(work, 'package');
    const collected = store.collectPackageFiles(root);
    for (const source of Object.values(collected)) {
      const destSource = path.join(pkgRoot, path.relative(root, source));
      fs.mkdirSync(path.dirname(destSource), { recursive: true });
      fs.copyFileSync(source, destSource);
    }
    fs.appendFileSync(path.join(pkgRoot, rel), '\nupstream revision\n');
    const ctx = install.makeContext({ targetRoot });
    ctx.pkgRoot = pkgRoot;
    ctx.version = 'next';
    install.copyVerbatim(ctx);
    install.copyDocs(ctx);
    install.recordVersion(ctx);
    assert.strictEqual(ctx.log.entries.find(e => e.path === rel).action, 'update');
    assert.match(fs.readFileSync(dest, 'utf8'), /upstream revision/);
    assert.strictEqual(store.readManifest(targetRoot).files[rel], store.hashFile(dest));
    assert.strictEqual(store.readManifest(targetRoot).nogging_version, 'next');
  });
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
console.log('Nogging: all manifest-update checks passed');
NODE
