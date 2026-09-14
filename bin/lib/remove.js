'use strict';

const fs = require('fs');
const path = require('path');

const manifest = require('./manifest');
const { GUARD_MARKER } = require('./merge');

function sourceFiles(root, rel, prefix = rel) {
  const full = path.join(root, rel);
  if (!fs.existsSync(full)) return [];
  const out = [];
  for (const entry of fs.readdirSync(full, { withFileTypes: true })) {
    const child = path.join(rel, entry.name);
    const target = path.join(prefix, entry.name);
    if (entry.isDirectory()) out.push(...sourceFiles(root, child, target));
    else out.push(target);
  }
  return out;
}

function removeFile(ctx, rel) {
  const full = path.join(ctx.targetRoot, rel);
  if (!fs.existsSync(full)) return;
  if (ctx.dryRun) {
    ctx.log.add('remove', rel, 'dry-run');
    return;
  }
  fs.rmSync(full, { force: true });
  ctx.log.add('remove', rel);
}

function removeMarkerBlock(ctx, rel) {
  const full = path.join(ctx.targetRoot, rel);
  if (!fs.existsSync(full)) return;
  const cur = fs.readFileSync(full, 'utf8');
  const begin = cur.indexOf(manifest.markerBegin);
  const end = cur.indexOf(manifest.markerEnd, begin);
  if (begin < 0 || end < 0) return;
  const after = end + manifest.markerEnd.length;
  const next = (cur.slice(0, begin) + cur.slice(after).replace(/^\n/, '')).replace(/\n{3,}/g, '\n\n');
  if (!ctx.dryRun) fs.writeFileSync(full, next);
  ctx.log.add('remove', `${rel} managed block`, ctx.dryRun ? 'dry-run' : undefined);
}

function removeClaudeGuard(ctx) {
  const rel = '.claude/settings.json';
  const full = path.join(ctx.targetRoot, rel);
  if (!fs.existsSync(full)) return;
  let data;
  try { data = JSON.parse(fs.readFileSync(full, 'utf8')); } catch (_) { return; }
  const pre = data?.hooks?.PreToolUse;
  if (!Array.isArray(pre)) return;
  const kept = pre.filter((entry) => !(
    Array.isArray(entry?.hooks) && entry.hooks.some((hook) =>
      typeof hook?.command === 'string' && hook.command.includes(GUARD_MARKER)
    )
  ));
  if (kept.length === pre.length) return;
  data.hooks.PreToolUse = kept;
  if (!ctx.dryRun) fs.writeFileSync(full, JSON.stringify(data, null, 2) + '\n');
  ctx.log.add('remove', 'Nogging Claude guard', ctx.dryRun ? 'dry-run' : undefined);
}

function removeInstallation(ctx) {
  for (const rel of manifest.verbatim) removeFile(ctx, rel);
  for (const dir of manifest.verbatimDirs) {
    for (const rel of sourceFiles(ctx.pkgRoot, dir.from, dir.to)) removeFile(ctx, rel);
  }
  for (const doc of manifest.docs) removeFile(ctx, doc.to);
  for (const unit of manifest.systemd) removeFile(ctx, unit.to.replace('{slug}', ctx.slug));
  removeMarkerBlock(ctx, 'CLAUDE.md');
  removeMarkerBlock(ctx, 'AGENTS.md');
  removeClaudeGuard(ctx);
  ctx.notes.push('Target-owned OpenSpec, Beads, .specforge configuration/state, and unrelated settings were preserved.');
  ctx.notes.push('Review shared .gitignore entries and Git hooks manually; ownership cannot be inferred safely.');
}

module.exports = { removeInstallation };
