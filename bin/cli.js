#!/usr/bin/env node
'use strict';

const install = require('./lib/install');

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
  --force        Allow init over an existing install
  --no-hooks     Skip installing the git hooks
  --no-systemd   Skip rendering the systemd sync unit
  -h, --help     Show this help
`;

function parseArgs(argv) {
  const args = { command: null, dryRun: false, force: false, noHooks: false, noSystemd: false, help: false };
  for (const a of argv) {
    switch (a) {
      case '-h':
      case '--help': args.help = true; break;
      case '--dry-run': args.dryRun = true; break;
      case '--force': args.force = true; break;
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
}

function cmdInit(args) {
  const ctx = install.makeContext(args);
  install.copyVerbatim(ctx);
  install.copyDocs(ctx);
  install.writeScaffold(ctx);
  install.recordVersion(ctx);
  report(ctx);
  if (ctx.dryRun) process.stdout.write('\n(dry run — nothing written)\n');
}

function cmdUpdate(args) {
  const ctx = install.makeContext(args);
  const fs = require('fs');
  const path = require('path');
  if (!fs.existsSync(path.join(ctx.targetRoot, '.specforge/config.json'))) {
    throw Object.assign(new Error('no .specforge/config.json — run `init` first'), { userFacing: true });
  }
  install.copyVerbatim(ctx);
  install.copyDocs(ctx);
  install.recordVersion(ctx);
  report(ctx);
  if (ctx.dryRun) process.stdout.write('\n(dry run — nothing written)\n');
}

function cmdDoctor() {
  const { spawnSync } = require('child_process');
  const fs = require('fs');
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
