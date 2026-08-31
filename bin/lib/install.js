'use strict';

const fs = require('fs');
const path = require('path');

const manifest = require('./manifest');
const fsops = require('./fsops');

const PKG_ROOT = path.resolve(__dirname, '..', '..');

function packageVersion() {
  try {
    return require(path.join(PKG_ROOT, 'package.json')).version || '0.0.0';
  } catch (_) {
    return '0.0.0';
  }
}

function slugify(name) {
  return (
    String(name)
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '') || 'repo'
  );
}

// Build the shared context for an install run. Throws if cwd is not a git root.
function makeContext(opts) {
  const targetRoot = opts.targetRoot || process.cwd();
  if (!fs.existsSync(path.join(targetRoot, '.git'))) {
    const err = new Error(
      'not a git repository root — run this from the top of the repo you want SpecForge in',
    );
    err.userFacing = true;
    throw err;
  }
  const repoName = path.basename(targetRoot);
  return {
    pkgRoot: PKG_ROOT,
    targetRoot,
    repoName,
    slug: slugify(repoName),
    version: packageVersion(),
    dryRun: !!opts.dryRun,
    noHooks: !!opts.noHooks,
    noSystemd: !!opts.noSystemd,
    log: new fsops.ChangeLog(),
  };
}

function src(ctx, rel) {
  return path.join(ctx.pkgRoot, rel);
}

// --- phases -----------------------------------------------------------------

function copyVerbatim(ctx) {
  for (const rel of manifest.verbatim) {
    const mode = manifest.executable.includes(rel) ? 0o755 : undefined;
    fsops.copyFile(src(ctx, rel), rel, ctx, { mode });
  }
  for (const dir of manifest.verbatimDirs) {
    fsops.copyDir(src(ctx, dir.from), dir.to, ctx);
  }
}

function copyDocs(ctx) {
  for (const doc of manifest.docs) {
    fsops.copyFile(src(ctx, doc.from), doc.to, ctx);
  }
}

function renderScaffoldConfig(ctx, raw) {
  let data;
  try {
    data = JSON.parse(raw);
  } catch (_) {
    data = {};
  }
  data.name = ctx.repoName;
  data.specforge_version = ctx.version;
  return JSON.stringify(data, null, 2) + '\n';
}

function writeScaffold(ctx) {
  for (const item of manifest.scaffold) {
    let content = fs.readFileSync(src(ctx, item.from), 'utf8');
    if (item.transform === 'specforgeConfig') {
      content = renderScaffoldConfig(ctx, content);
    }
    fsops.writeIfAbsent(item.to, content, ctx);
  }
}

// Bump the recorded SpecForge version in an existing .specforge/config.json.
function recordVersion(ctx) {
  const rel = '.specforge/config.json';
  const cur = fsops.readTarget(rel, ctx);
  if (cur == null) return;
  let data;
  try {
    data = JSON.parse(cur);
  } catch (_) {
    return;
  }
  if (data.specforge_version === ctx.version) {
    ctx.log.add('unchanged', rel);
    return;
  }
  data.specforge_version = ctx.version;
  fsops.writeFile(rel, JSON.stringify(data, null, 2) + '\n', ctx);
}

module.exports = {
  PKG_ROOT,
  packageVersion,
  slugify,
  makeContext,
  src,
  copyVerbatim,
  copyDocs,
  writeScaffold,
  recordVersion,
};
