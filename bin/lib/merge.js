'use strict';

const fs = require('fs');
const path = require('path');

const manifest = require('./manifest');
const fsops = require('./fsops');

const GUARD_MARKER = 'pre-tool-use-openspec-guard';
const GUARD_ENTRY = {
  matcher: 'Edit|Write',
  hooks: [
    {
      type: 'command',
      command: '"$CLAUDE_PROJECT_DIR"/scripts/hooks/pre-tool-use-openspec-guard',
    },
  ],
};

function parseJsonOr(raw, fallback) {
  if (raw == null || raw.trim() === '') return fallback;
  try {
    return JSON.parse(raw);
  } catch (_) {
    return fallback;
  }
}

// Ensure .claude/settings.json wires the PreToolUse OpenSpec guard exactly once,
// leaving every other setting and hook untouched.
function mergeClaudeSettings(ctx) {
  const rel = '.claude/settings.json';
  const cur = fsops.readTarget(rel, ctx);
  const data = parseJsonOr(cur, {});

  data.hooks = data.hooks && typeof data.hooks === 'object' ? data.hooks : {};
  const pre = Array.isArray(data.hooks.PreToolUse) ? data.hooks.PreToolUse : [];

  const has = pre.some((entry) =>
    Array.isArray(entry && entry.hooks) &&
    entry.hooks.some((h) => h && typeof h.command === 'string' && h.command.includes(GUARD_MARKER)),
  );

  if (has) {
    ctx.log.add('unchanged', rel);
    return;
  }

  pre.push(JSON.parse(JSON.stringify(GUARD_ENTRY)));
  data.hooks.PreToolUse = pre;
  fsops.writeFile(rel, JSON.stringify(data, null, 2) + '\n', ctx);
}

// Ensure the SpecForge ignore lines are present, once, under a comment header.
function mergeGitignore(ctx) {
  const rel = '.gitignore';
  const cur = fsops.readTarget(rel, ctx) || '';
  const lines = cur.split('\n');
  const missing = manifest.gitignore.filter((want) => !lines.some((l) => l.trim() === want));

  if (missing.length === 0) {
    if (cur !== '') ctx.log.add('unchanged', rel);
    return;
  }

  let next = cur;
  if (next !== '' && !next.endsWith('\n')) next += '\n';
  if (next !== '' && !next.endsWith('\n\n')) next += '\n';
  next += '# SpecForge\n' + missing.join('\n') + '\n';
  fsops.writeFile(rel, next, ctx);
}

// Insert or replace the SpecForge block delimited by the manifest markers.
// Content outside the markers is never touched.
function mergeMarkerBlock(ctx, rel, body) {
  const begin = manifest.markerBegin;
  const end = manifest.markerEnd;
  const block = `${begin}\n${body.trimEnd()}\n${end}\n`;
  const cur = fsops.readTarget(rel, ctx);

  if (cur == null) {
    fsops.writeFile(rel, block, ctx);
    return;
  }

  const bIdx = cur.indexOf(begin);
  const eIdx = cur.indexOf(end);
  if (bIdx !== -1 && eIdx !== -1 && eIdx > bIdx) {
    const before = cur.slice(0, bIdx);
    const after = cur.slice(eIdx + end.length).replace(/^\n/, '');
    const next = before + block + after;
    if (next === cur) ctx.log.add('unchanged', rel);
    else fsops.writeFile(rel, next, ctx);
    return;
  }

  let next = cur;
  if (!next.endsWith('\n')) next += '\n';
  next += '\n' + block;
  fsops.writeFile(rel, next, ctx);
}

function readTemplate(ctx, rel) {
  return fs.readFileSync(path.join(ctx.pkgRoot, rel), 'utf8');
}

function applyMerges(ctx) {
  mergeClaudeSettings(ctx);
  mergeGitignore(ctx);
  mergeMarkerBlock(ctx, 'CLAUDE.md', readTemplate(ctx, 'templates/claude-block.md'));
  mergeMarkerBlock(ctx, 'AGENTS.md', readTemplate(ctx, 'templates/agents-block.md'));
}

module.exports = {
  GUARD_MARKER,
  GUARD_ENTRY,
  mergeClaudeSettings,
  mergeGitignore,
  mergeMarkerBlock,
  applyMerges,
};
