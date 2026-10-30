'use strict';

const fs = require('fs');
const path = require('path');

const manifest = require('./manifest');
const fsops = require('./fsops');

function render(tmpl, ctx) {
  return tmpl
    .replace(/\{\{WORKDIR\}\}/g, ctx.targetRoot)
    .replace(/\{\{SLUG\}\}/g, ctx.slug)
    .replace(/\{\{NAME\}\}/g, ctx.repoName);
}

// Render the systemd sync service + timer with the target repo's absolute path
// and a per-repo slug so units for different repos never collide.
function renderSystemd(ctx) {
  ctx.log.setClass('units');
  if (ctx.noSystemd) {
    ctx.log.add('skip', 'systemd/', '--no-systemd');
    return;
  }
  const written = [];
  for (const item of manifest.systemd) {
    const tmpl = fs.readFileSync(path.join(ctx.pkgRoot, item.from), 'utf8');
    const dest = item.to.replace('{slug}', ctx.slug);
    fsops.writeFile(dest, render(tmpl, ctx), ctx);
    written.push(dest);
  }
  // The next-steps block (nextsteps.js) names the units that can be enabled.
  for (const rel of written) {
    if (rel.endsWith('.timer')) ctx.units.push({ kind: 'timer', rel });
    else if (rel.includes('orchestrator')) ctx.units.push({ kind: 'orchestrator', rel });
  }
}

module.exports = { render, renderSystemd };
