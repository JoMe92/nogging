'use strict';

const fs = require('fs');
const path = require('path');
const manifestStore = require('./manifest-store');

// A running log of what an install run did (or would do, under --dry-run).
class ChangeLog {
  constructor() {
    this.entries = [];
    this.cls = null;
  }

  // Tag the entries added from here on with the file class of the manifest
  // entry that produces them (see report.js CLASSES).
  setClass(cls) {
    this.cls = cls;
  }

  add(action, relPath, note) {
    this.entries.push({ action, path: relPath, note, cls: this.cls });
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
  // Without a recorded digest (legacy install, no manifest), fall back to the
  // bundled release baselines: a file matching one is an unmodified old release.
  const recordedDigest = manifestStore.getRecordedDigest(ctx.installedManifest, destRel)
    || (curDigest ? manifestStore.resolveRecordedDigest({
      manifestObj: ctx.installedManifest || { files: {} },
      relPath: destRel,
      recordedVersion: ctx.recordedVersion,
      curDigest,
    }) : null);
  const state = manifestStore.evaluateFileState({ curDigest, nextDigest, recordedDigest });
  // An explicit mode wins; otherwise a packaged executable installs as 0755.
  const wantMode = mode != null ? mode
    : (fs.statSync(srcAbs).mode & 0o111) ? 0o755 : null;
  // Content already matches but the executable bit was lost (e.g. by an earlier
  // update): repair it, which is safe because the file equals the package.
  const repair = state === 'unchanged' && wantMode != null && (wantMode & 0o111) !== 0
    && (fs.statSync(destAbs).mode & 0o111) === 0;
  const action = repair ? 'update' : state === 'preserve' && ctx.force ? 'force-overwrite' : state;
  const outputAbs = action === 'preserve' ? `${destAbs}.nogging-new` : destAbs;
  if (repair) {
    if (!ctx.dryRun) fs.chmodSync(destAbs, fs.statSync(destAbs).mode & 0o7777 | 0o111);
  } else if (action !== 'unchanged' && !ctx.dryRun) {
    ensureDir(path.dirname(outputAbs), ctx);
    if (action === 'force-overwrite') fs.copyFileSync(destAbs, `${destAbs}.orig`);
    fs.writeFileSync(outputAbs, next);
    if (wantMode != null) fs.chmodSync(outputAbs, wantMode);
  }
  if (ctx.nextInstalledManifest && action !== 'preserve') {
    ctx.nextInstalledManifest.files[destRel] = nextDigest;
  }
  if (action === 'preserve' || action === 'force-overwrite') {
    (ctx.review ||= []).push({ kind: action === 'preserve' ? 'preserve' : 'force', path: destRel });
  }
  const note = repair ? `mode ${(wantMode & 0o777).toString(8).padStart(4, '0')}`
    : action === 'preserve' ? `upstream: ${destRel}.nogging-new`
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
