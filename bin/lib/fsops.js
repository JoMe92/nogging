'use strict';

const fs = require('fs');
const path = require('path');

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

// Copy a single file, recording create/overwrite/unchanged.
function copyFile(srcAbs, destRel, ctx, { mode } = {}) {
  const destAbs = path.join(ctx.targetRoot, destRel);
  const next = fs.readFileSync(srcAbs);
  let action = 'create';
  if (fs.existsSync(destAbs)) {
    const cur = fs.readFileSync(destAbs);
    action = cur.equals(next) ? 'unchanged' : 'overwrite';
  }
  if (action !== 'unchanged' && !ctx.dryRun) {
    ensureDir(path.dirname(destAbs), ctx);
    fs.writeFileSync(destAbs, next);
  }
  if (mode != null && !ctx.dryRun && fs.existsSync(destAbs)) {
    fs.chmodSync(destAbs, mode);
  }
  ctx.log.add(action, destRel);
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
