#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const install = require('./lib/install');
const { applyMerges } = require('./lib/merge');
const { renderSystemd } = require('./lib/systemd');

const USAGE = `specforge — install the SpecForge operating structure into a repo

Usage:
  npx github:JoMe92/specforge <command> [options]

Commands:
  init      Install SpecForge into the current git repository
  update    Refresh SpecForge tool files and re-apply merges (keeps your
            openspec/changes, openspec/project.md and config name)
  doctor    Run the installed ./scripts/specforge doctor

Options:
  --dry-run      Show what would change, write nothing
  --no-hooks     Skip installing the git hooks
  --no-systemd   Skip rendering the systemd sync unit
  -h, --help     Show this help

init is idempotent and safe to re-run; use update for routine refreshes.
`;

function parseArgs(argv) {
  const args = { command: null, dryRun: false, noHooks: false, noSystemd: false, help: false };
  for (const a of argv) {
    switch (a) {
      case '-h':
      case '--help': args.help = true; break;
      case '--dry-run': args.dryRun = true; break;
      case '--no-hooks': args.noHooks = true; break;
      case '--no-systemd': args.noSystemd = true; break;
      default:
        if (a.startsWith('-')) {
          throw Object.assign(new Error(`unknown option: ${a}`), { userFacing: true });
        }
        if (!args.command) args.command = a;
        else throw Object.assign(new Error(`unexpected argument: ${a}`), { userFacing: true });
    }
  }
  return args;
}

function report(ctx) {
  const verb = ctx.dryRun ? 'Would change' : 'Changed';
  process.stdout.write(`\n${verb}:\n${ctx.log.render()}\n`);
  if (ctx.warnings.length) {
    process.stdout.write('\nWarnings:\n');
    for (const w of ctx.warnings) process.stdout.write(`  - ${w}\n`);
  }
  if (ctx.notes.length && !ctx.dryRun) {
    process.stdout.write('\nNext steps:\n');
    for (const n of ctx.notes) process.stdout.write(`  - ${n}\n`);
  }
  if (ctx.dryRun) process.stdout.write('\n(dry run — nothing written)\n');
}

function cmdInit(args) {
  const ctx = install.makeContext(args);
  const reinstall = fs.existsSync(path.join(ctx.targetRoot, '.specforge/config.json'));
  if (reinstall && !ctx.dryRun) {
    process.stdout.write(
      'SpecForge is already installed here; re-running init idempotently ' +
        '(use `update` for routine refreshes).\n',
    );
  }
  install.copyVerbatim(ctx);
  install.copyDocs(ctx);
  install.writeScaffold(ctx);
  applyMerges(ctx);
  renderSystemd(ctx);
  install.recordVersion(ctx);
  install.installGitHooks(ctx);
  install.beadsHint(ctx);
  report(ctx);
}

function cmdUpdate(args) {
  const ctx = install.makeContext(args);
  if (!fs.existsSync(path.join(ctx.targetRoot, '.specforge/config.json'))) {
    throw Object.assign(new Error('no .specforge/config.json — run `init` first'), { userFacing: true });
  }
  install.copyVerbatim(ctx);
  install.copyDocs(ctx);
  applyMerges(ctx);
  renderSystemd(ctx);
  install.recordVersion(ctx);
  install.installGitHooks(ctx);
  report(ctx);
}

function cmdDoctor() {
  const { spawnSync } = require('child_process');
  if (!fs.existsSync('scripts/specforge')) {
    throw Object.assign(new Error('scripts/specforge not found — run `init` first'), { userFacing: true });
  }
  const r = spawnSync('scripts/specforge', ['doctor'], { stdio: 'inherit' });
  process.exit(r.status == null ? 1 : r.status);
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`specforge: ${e.message}\n`);
    process.exit(2);
  }

  if (args.help || !args.command) {
    process.stdout.write(USAGE);
    process.exit(args.command ? 0 : (args.help ? 0 : 1));
  }

  try {
    switch (args.command) {
      case 'init': cmdInit(args); break;
      case 'update': cmdUpdate(args); break;
      case 'doctor': cmdDoctor(args); break;
      default:
        process.stderr.write(`specforge: unknown command: ${args.command}\n`);
        process.exit(2);
    }
  } catch (e) {
    process.stderr.write(`specforge: ${e.userFacing ? e.message : e.stack || e.message}\n`);
    process.exit(1);
  }
}

main();
