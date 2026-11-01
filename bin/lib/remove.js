'use strict';

const fs = require('fs');
const path = require('path');

const manifest = require('./manifest');
const { GUARD_MARKER } = require('./merge');
const { MANIFEST_REL_PATH } = require('./manifest-store');

const ARTIFACT_SUFFIXES = ['.nogging-new', '.orig'];

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

// A managed file is removed together with the `.nogging-new` / `.orig`
// artifacts the installer may have left beside it.
function removeManagedFile(ctx, rel) {
  removeFile(ctx, rel);
  for (const suffix of ARTIFACT_SUFFIXES) removeFile(ctx, rel + suffix);
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

function removeAntigravityHooks(ctx) {
  const rel = '.agents/hooks.json';
  const full = path.join(ctx.targetRoot, rel);
  if (!fs.existsSync(full)) return;
  const data = JSON.parse(fs.readFileSync(full, 'utf8'));
  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    throw new Error(`${rel} must contain a JSON object; refusing to replace user hooks`);
  }
  const owned = JSON.parse(fs.readFileSync(path.join(ctx.pkgRoot, 'templates/antigravity/hooks.json'), 'utf8'));
  let changed = false;
  for (const name of Object.keys(owned)) {
    if (Object.hasOwn(data, name)) {
      delete data[name];
      changed = true;
    }
  }
  if (!changed) return;
  if (!ctx.dryRun) fs.writeFileSync(full, JSON.stringify(data, null, 2) + '\n');
  ctx.log.add('remove', 'Nogging Antigravity hooks', ctx.dryRun ? 'dry-run' : undefined);
}

function removeInstallation(ctx) {
  ctx.log.setClass('tools');
  for (const rel of manifest.verbatim) removeManagedFile(ctx, rel);
  ctx.log.setClass('agents');
  for (const dir of manifest.verbatimDirs) {
    for (const rel of sourceFiles(ctx.pkgRoot, dir.from, dir.to)) removeManagedFile(ctx, rel);
  }
  ctx.log.setClass('docs');
  for (const doc of manifest.docs) removeManagedFile(ctx, doc.to);
  ctx.log.setClass('merge');
  removeFile(ctx, MANIFEST_REL_PATH);
  ctx.log.setClass('units');
  for (const unit of manifest.systemd) {
    const rel = unit.to.replace('{slug}', ctx.slug);
    // Enable-able units, named by the next steps so they can be disabled first.
    if (fs.existsSync(path.join(ctx.targetRoot, rel))) {
      if (rel.endsWith('.timer')) ctx.units.push({ kind: 'timer', rel });
      else if (path.basename(rel).startsWith('nogg-orchestrator-')) ctx.units.push({ kind: 'orchestrator', rel });
    }
    removeFile(ctx, rel);
  }
  // The nightly run's retained worktree is Git's to remove; the next steps name it.
  const nightlyWorktree = `${ctx.targetRoot}-nightly`;
  if (fs.existsSync(nightlyWorktree)) ctx.nightlyWorktree = nightlyWorktree;
  ctx.log.setClass('merge');
  removeMarkerBlock(ctx, 'CLAUDE.md');
  removeMarkerBlock(ctx, 'AGENTS.md');
  removeClaudeGuard(ctx);
  removeAntigravityHooks(ctx);
  ctx.notes.push('Target-owned OpenSpec, Beads, .nogging configuration/state, and unrelated settings were preserved.');
}

module.exports = { removeInstallation };
