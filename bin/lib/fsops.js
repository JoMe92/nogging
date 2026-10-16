'use strict';

const fs = require('fs');
const path = require('path');
const manifestStore = require('./manifest-store');

// A running log of what an install run did (or would do, under --dry-run).
class ChangeLog {
  constructor() {
    this.entries = [];
  }

  add(action, relPath, note) {
    this.entries.push({ action, path: relPath, note });
  }

  // action counts, ignoring 'unchanged'
  touched() {
    return this.entries.filter((e) => e.action !== 'unchanged');
  }

  render() {
    if (this.entries.length === 0) return '  (nothing to do)';
    return this.entries
      .map((e) => {
        const tag = e.action.padEnd(9);
        return `  ${tag} ${e.path}${e.note ? `  (${e.note})` : ''}`;
      })
      .join('\n');
  }
}

function ensureDir(absDir, ctx) {
  if (fs.existsSync(absDir)) return;
  if (!ctx.dryRun) fs.mkdirSync(absDir, { recursive: true });
}

// Copy managed content using its last accepted upstream digest as the baseline.
function copyFile(srcAbs, destRel, ctx, { mode } = {}) {
  const destAbs = path.join(ctx.targetRoot, destRel);
  const next = fs.readFileSync(srcAbs);
  const nextDigest = manifestStore.sha256(next);
  const curDigest = fs.existsSync(destAbs)
    ? manifestStore.sha256(fs.readFileSync(destAbs)) : null;
  const recordedDigest = manifestStore.getRecordedDigest(ctx.installedManifest, destRel);
  const state = manifestStore.evaluateFileState({ curDigest, nextDigest, recordedDigest });
  const action = state === 'preserve' && ctx.force ? 'force-overwrite' : state;
  const outputAbs = action === 'preserve' ? `${destAbs}.nogging-new` : destAbs;
  if (action !== 'unchanged' && !ctx.dryRun) {
    ensureDir(path.dirname(outputAbs), ctx);
    if (action === 'force-overwrite') fs.copyFileSync(destAbs, `${destAbs}.orig`);
    fs.writeFileSync(outputAbs, next);
  }
  if (mode != null && action !== 'unchanged' && !ctx.dryRun) {
    fs.chmodSync(outputAbs, mode);
  }
  if (ctx.nextInstalledManifest && action !== 'preserve') {
    ctx.nextInstalledManifest.files[destRel] = nextDigest;
  }
  if (action === 'preserve') {
    ctx.warnings.push(
      `locally modified file preserved: ${destRel} (upstream ${ctx.dryRun ? 'would be written' : 'written'} to ${destRel}.nogging-new)`,
    );
  } else if (action === 'force-overwrite') {
    ctx.warnings.push(
      `locally modified file overwritten (--force): ${destRel} (backup ${ctx.dryRun ? 'would be saved' : 'saved'} to ${destRel}.orig)`,
    );
  }
  const note = action === 'preserve' ? `upstream: ${destRel}.nogging-new`
    : action === 'force-overwrite' ? `backup: ${destRel}.orig` : undefined;
  ctx.log.add(action, destRel, note);
  return action;
}

// Recursively copy a directory tree, file by file.
function copyDir(srcAbs, destRel, ctx) {
  for (const entry of fs.readdirSync(srcAbs, { withFileTypes: true })) {
    const childSrc = path.join(srcAbs, entry.name);
    const childDestRel = path.posix.join(destRel, entry.name);
    if (entry.isDirectory()) {
      copyDir(childSrc, childDestRel, ctx);
    } else if (entry.isFile()) {
      copyFile(childSrc, childDestRel, ctx);
    }
  }
}

// Write literal content only when the destination is absent.
function writeIfAbsent(destRel, content, ctx) {
  const destAbs = path.join(ctx.targetRoot, destRel);
  if (fs.existsSync(destAbs)) {
    ctx.log.add('keep', destRel, 'exists');
    return false;
  }
  if (!ctx.dryRun) {
    ensureDir(path.dirname(destAbs), ctx);
    fs.writeFileSync(destAbs, content);
  }
  ctx.log.add('create', destRel);
  return true;
}

// Write content, recording create/overwrite/unchanged.
function writeFile(destRel, content, ctx, { mode } = {}) {
  const destAbs = path.join(ctx.targetRoot, destRel);
  let action = 'create';
  if (fs.existsSync(destAbs)) {
    action = fs.readFileSync(destAbs, 'utf8') === content ? 'unchanged' : 'overwrite';
  }
  if (action !== 'unchanged' && !ctx.dryRun) {
    ensureDir(path.dirname(destAbs), ctx);
    fs.writeFileSync(destAbs, content);
  }
  if (mode != null && !ctx.dryRun && fs.existsSync(destAbs)) {
    fs.chmodSync(destAbs, mode);
  }
  ctx.log.add(action, destRel);
  return action;
}

function readTarget(destRel, ctx) {
  const destAbs = path.join(ctx.targetRoot, destRel);
  return fs.existsSync(destAbs) ? fs.readFileSync(destAbs, 'utf8') : null;
}

module.exports = {
  ChangeLog,
  ensureDir,
  copyFile,
  copyDir,
  writeIfAbsent,
  writeFile,
  readTarget,
};
