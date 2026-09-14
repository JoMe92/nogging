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
      'not a git repository root — run this from the top of the repo you want Nogging in',
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
    noBeads: !!opts.noBeads,
    noHooks: !!opts.noHooks,
    noSystemd: !!opts.noSystemd,
    log: new fsops.ChangeLog(),
    notes: [],
    warnings: [],
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
  data.nogging_version = ctx.version;
  return JSON.stringify(data, null, 2) + '\n';
}

function writeScaffold(ctx) {
  for (const item of manifest.scaffold) {
    let content = fs.readFileSync(src(ctx, item.from), 'utf8');
    if (item.transform === 'noggingConfig') {
      content = renderScaffoldConfig(ctx, content);
    }
    fsops.writeIfAbsent(item.to, content, ctx);
  }
}

// Bump the recorded SpecForge version in an existing .nogging/config.json.
function recordVersion(ctx) {
  const rel = '.nogging/config.json';
  const cur = fsops.readTarget(rel, ctx);
  if (cur == null) return;
  let data;
  try {
    data = JSON.parse(cur);
  } catch (_) {
    return;
  }
  if (data.nogging_version === ctx.version) return;
  data.nogging_version = ctx.version;
  fsops.writeFile(rel, JSON.stringify(data, null, 2) + '\n', ctx);
}

// Install the two git hooks, unless core.hooksPath diverts Git away from
// .git/hooks (the known Beads collision) — in that case warn instead.
function installGitHooks(ctx) {
  if (ctx.noHooks) {
    ctx.log.add('skip', '.git/hooks', '--no-hooks');
    return;
  }
  const { spawnSync } = require('child_process');
  const hp = spawnSync('git', ['config', '--get', 'core.hooksPath'], {
    cwd: ctx.targetRoot,
    encoding: 'utf8',
  });
  const configured = (hp.stdout || '').trim();
  if (configured && path.resolve(ctx.targetRoot, configured) !== path.join(ctx.targetRoot, '.git', 'hooks')) {
    ctx.warnings.push(
      `core.hooksPath is set to "${configured}", so Git will not run the Nogging\n` +
        '  pre-commit and commit-msg boundary hooks from .git/hooks. Install them into\n' +
        `  that directory yourself, or clear core.hooksPath. (scripts/hooks/ hold the sources.)`,
    );
    return;
  }
  if (ctx.dryRun) {
    ctx.log.add('run', 'scripts/install-hooks', 'dry-run');
    return;
  }
  const r = spawnSync('scripts/install-hooks', [], { cwd: ctx.targetRoot, stdio: 'ignore' });
  ctx.log.add(r.status === 0 ? 'run' : 'warn', 'scripts/install-hooks', r.status === 0 ? undefined : 'failed');
  if (r.status !== 0) {
    ctx.warnings.push('scripts/install-hooks failed — install the git hooks manually.');
  }
}

function beadsHint(ctx) {
  if (!fs.existsSync(path.join(ctx.targetRoot, '.beads'))) {
    ctx.notes.push('Initialize the issue tracker:\n    bd init');
  }
}

// Run the installed `scripts/nogg doctor` checks plus a tracker check and
// print a single readiness verdict. The installer never installs system tools;
// this only tells the operator whether the repo is ready to plan.
function readinessVerdict(ctx) {
  if (ctx.dryRun) return;
  const gaps = [];
  if (!fs.existsSync(path.join(ctx.targetRoot, '.beads'))) {
    gaps.push('uninitialized tracker (run `bd init`)');
  }
  if (fs.existsSync(path.join(ctx.targetRoot, 'scripts', 'nogg'))) {
    const { spawnSync } = require('child_process');
    const r = spawnSync('scripts/nogg', ['doctor'], {
      cwd: ctx.targetRoot,
      encoding: 'utf8',
    });
    if (r.error) {
      gaps.push('scripts/nogg doctor could not run');
    } else {
      for (const line of `${r.stdout || ''}\n${r.stderr || ''}`.split('\n')) {
        const m = line.match(/^FAIL\s+(.+)$/);
        if (m) gaps.push(m[1].trim());
      }
    }
  } else {
    gaps.push('scripts/nogg missing');
  }
  const uniq = [...new Set(gaps)];
  process.stdout.write('\n');
  if (uniq.length === 0) {
    process.stdout.write('Nogging is ready — run ./scripts/nogg plan-begin to start.\n');
  } else {
    process.stdout.write(`Nogging is installed but not ready: ${uniq.join('; ')}\n`);
  }
}

// Initialize the Beads tracker in the target repo as the first install step.
// Idempotent, and never fatal: a missing `bd` or an unreachable backend is a
// warning that the readiness verdict will also surface.
function initBeads(ctx) {
  const rel = '.beads';
  if (ctx.noBeads) {
    ctx.log.add('skip', rel, '--no-beads');
    return;
  }
  if (fs.existsSync(path.join(ctx.targetRoot, rel))) {
    ctx.log.add('keep', rel, 'exists');
    return;
  }
  if (ctx.dryRun) {
    ctx.log.add('run', 'bd init', 'dry-run');
    return;
  }
  const { spawnSync } = require('child_process');
  const r = spawnSync('bd', ['init', '--init-if-missing', '--non-interactive'], {
    cwd: ctx.targetRoot,
    encoding: 'utf8',
  });
  if (r.error && r.error.code === 'ENOENT') {
    ctx.warnings.push('bd (Beads) is not installed — install it, then run `bd init` in this repo.');
    return;
  }
  if (r.status !== 0) {
    const first = ((r.stderr || r.stdout || '').trim().split('\n')[0]) || 'unknown error';
    ctx.warnings.push(`bd init failed (${first}) — run \`bd init\` once the backend is reachable.`);
    return;
  }
  ctx.log.add('run', 'bd init');
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
  installGitHooks,
  beadsHint,
  initBeads,
  readinessVerdict,
};
