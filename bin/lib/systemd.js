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
  const timer = written.find((p) => p.endsWith('.timer'));
  if (timer) {
    ctx.notes.push(
      'Enable the sync timer:\n' +
        `    systemctl --user enable --now "$PWD/${timer}"`,
    );
  }
}

module.exports = { render, renderSystemd };
