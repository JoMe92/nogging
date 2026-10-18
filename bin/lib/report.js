'use strict';

// Renders an install run: a header, changes grouped by file class with counts,
// one review block for preserved and forced files, and deduplicated warnings.
// Entries come from ctx.log (ChangeLog), which tags each one with the file
// class of the manifest entry that produced it.

const path = require('path');

// Display order and labels of the file classes.
const CLASSES = [
  ['tools', 'Tool scripts'],
  ['agents', 'Agent payloads'],
  ['docs', 'Reference docs'],
  ['scaffold', 'Scaffold'],
  ['merge', 'Merged configuration'],
  ['units', 'Rendered units'],
  ['tracker', 'Tracker and hooks'],
];
const FALLBACK_CLASS = 'tools';

// When several entries log the same path, the most significant action wins.
const RANK = {
  preserve: 5,
  'force-overwrite': 4,
  create: 3, update: 3, overwrite: 3, remove: 3, migrate: 3, run: 3, warn: 3,
  keep: 2, skip: 2,
  unchanged: 1,
};

// Count labels per action: [real run, dry run].
const LABEL = {
  create: ['created', 'would create'],
  update: ['updated', 'would update'],
  overwrite: ['overwritten', 'would overwrite'],
  'force-overwrite': ['overwritten (--force)', 'would overwrite (--force)'],
  preserve: ['preserved', 'would preserve'],
  remove: ['removed', 'would remove'],
  migrate: ['migrated', 'would migrate'],
  run: ['ran', 'would run'],
  warn: ['failed', 'failed'],
  keep: ['already present', 'already present'],
  skip: ['skipped', 'skipped'],
  unchanged: ['unchanged', 'unchanged'],
};
const ACTION_ORDER = Object.keys(LABEL);

function label(action, dryRun) {
  const l = LABEL[action];
  return l ? l[dryRun ? 1 : 0] : action;
}

// One entry per path: the most significant action wins, first seen on a tie.
function consolidate(entries) {
  const byPath = new Map();
  for (const e of entries) {
    const cur = byPath.get(e.path);
    if (!cur || (RANK[e.action] || 3) > (RANK[cur.action] || 3)) byPath.set(e.path, e);
  }
  return [...byPath.values()];
}

function header(ctx, command, { previousVersion = null } = {}) {
  const where = path.resolve(ctx.targetRoot);
  const dry = ctx.dryRun ? ' (dry run)' : '';
  if (command === 'remove') return `Nogging — remove from ${where}${dry}`;
  let ver = `Nogging ${ctx.version}`;
  let tail = '';
  if (command === 'update') {
    if (previousVersion && previousVersion !== ctx.version) {
      ver = `Nogging ${previousVersion} → ${ctx.version}`;
    } else if (previousVersion) {
      tail = ` (already at ${ctx.version})`;
    }
  }
  return `${ver} — ${command} in ${where}${tail}${dry}`;
}

function countsLine(entries, dryRun) {
  const counts = {};
  for (const e of entries) counts[e.action] = (counts[e.action] || 0) + 1;
  const actions = Object.keys(counts).sort((a, b) => {
    const ia = ACTION_ORDER.indexOf(a);
    const ib = ACTION_ORDER.indexOf(b);
    return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
  });
  return actions.map((a) => `${counts[a]} ${label(a, dryRun)}`).join(', ');
}

function changes(ctx, verbose) {
  const entries = consolidate(ctx.log.entries);
  if (entries.length === 0) return ['Changes', '  (nothing to do)'];
  const known = new Set(CLASSES.map(([key]) => key));
  const lines = ['Changes'];
  const width = Math.max(...CLASSES.map(([, name]) => name.length));
  for (const [key, name] of CLASSES) {
    const group = entries.filter((e) => (known.has(e.cls) ? e.cls : FALLBACK_CLASS) === key);
    if (group.length === 0) continue;
    lines.push(`  ${name.padEnd(width)}  ${countsLine(group, ctx.dryRun)}`);
    if (!verbose) continue;
    for (const e of group) {
      lines.push(`    ${label(e.action, ctx.dryRun).padEnd(22)} ${e.path}`);
    }
  }
  return lines;
}

// Preserved and forced files, each once.
function review(ctx) {
  const items = [];
  const seen = new Set();
  for (const r of ctx.review || []) {
    if (seen.has(r.path)) continue;
    seen.add(r.path);
    items.push(r);
  }
  if (items.length === 0) return [];
  const dry = ctx.dryRun;
  const lines = ['Needs your review'];
  for (const r of items) {
    if (r.kind === 'preserve') {
      lines.push(dry
        ? `  ${r.path} — would keep your edit; upstream would go to ${r.path}.nogging-new`
        : `  ${r.path} — kept your edit; upstream in ${r.path}.nogging-new`);
    } else {
      lines.push(dry
        ? `  ${r.path} — would be overwritten (--force); backup would go to ${r.path}.orig`
        : `  ${r.path} — overwritten (--force); backup in ${r.path}.orig`);
    }
  }
  if (items.some((r) => r.kind === 'preserve')) {
    lines.push('  Review each .nogging-new, merge what you want, then delete it.');
    lines.push('  Re-run with --force to overwrite them instead (keeps <file>.orig backups).');
  }
  return lines;
}

function warnings(ctx) {
  const uniq = [...new Set(ctx.warnings)];
  if (uniq.length === 0) return [];
  return ['Warnings', ...uniq.map((w) => `  - ${w}`)];
}

function notes(ctx) {
  if (!ctx.notes.length || ctx.dryRun) return [];
  return ['Notes', ...ctx.notes.map((n) => `  - ${n}`)];
}

// The whole post-run report, as a string.
function render(ctx) {
  const blocks = [
    changes(ctx, !!ctx.verbose),
    review(ctx),
    warnings(ctx),
    notes(ctx),
  ].filter((b) => b.length);
  if (ctx.dryRun) blocks.push(['(dry run — nothing written)']);
  return `${blocks.map((b) => b.join('\n')).join('\n\n')}\n`;
}

module.exports = { CLASSES, header, render, consolidate };
