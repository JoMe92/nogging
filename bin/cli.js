#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const install = require('./lib/install');
const { applyMerges } = require('./lib/merge');
const { renderSystemd } = require('./lib/systemd');
const { removeInstallation } = require('./lib/remove');
const { version: VERSION } = require('../package.json');

const USAGE = `nogg — install the Nogging operating structure into a repo

Usage:
  npx github:JoMe92/nogging <command> [options]

Commands:
  version   Print the Nogging package version
  init      Install Nogging into the current git repository
  update    Refresh Nogging tool files and re-apply merges (keeps your
            openspec/changes, openspec/project.md and config name)
  remove    Remove managed payload while preserving project-owned state
  doctor    Run the installed ./scripts/nogg doctor

Options:
  --dry-run      Show what would change, write nothing
  --force        Overwrite locally modified verbatim files on init/update
                 (backs up each to <file>.orig; default keeps them and
                 writes upstream to <file>.nogging-new)
  --no-beads     Skip initializing the Beads issue tracker
  --no-hooks     Skip installing the git hooks
  --no-systemd   Skip rendering the systemd sync unit
  -v, --version  Print the Nogging package version
  -h, --help     Show this help

init is idempotent and safe to re-run; use update for routine refreshes.
`;

function parseArgs(argv) {
  const args = { command: null, dryRun: false, force: false, noBeads: false, noHooks: false, noSystemd: false, help: false, version: false };
  for (const a of argv) {
    switch (a) {
      case '-h':
      case '--help': args.help = true; break;
      case '--dry-run': args.dryRun = true; break;
      case '--force': args.force = true; break;
      case '--no-beads': args.noBeads = true; break;
      case '--no-hooks': args.noHooks = true; break;
      case '--no-systemd': args.noSystemd = true; break;
      case '-v':
      case '--version': args.version = true; break;
      default:
        if (a.startsWith('-')) {
          throw Object.assign(new Error(`unknown option: ${a}`), { userFacing: true });
        }
        if (!args.command) args.command = a;
        else throw Object.assign(new Error(`unexpected argument: ${a}`), { userFacing: true });
    }
  }
  if (args.force && args.command && args.command !== 'init' && args.command !== 'update') {
    throw Object.assign(new Error('--force only applies to init and update'), { userFacing: true });
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
  const preserved = ctx.log.entries.filter((e) => e.action === 'preserve');
  const forced = ctx.log.entries.filter((e) => e.action === 'force-overwrite');
  if (preserved.length) {
    const had = ctx.dryRun ? 'would be preserved' : 'preserved';
    process.stdout.write(`\nLocally modified files ${had} (upstream copies alongside):\n`);
    for (const e of preserved) process.stdout.write(`  - ${e.path}  ->  ${e.path}.nogging-new\n`);
    process.stdout.write('  Review each .nogging-new, merge what you want, then delete it.\n');
    process.stdout.write('  Re-run with --force to overwrite them instead (keeps <file>.orig backups).\n');
  }
  if (forced.length) {
    process.stdout.write(`\nLocally modified files ${ctx.dryRun ? 'would be ' : ''}overwritten (--force):\n`);
    for (const e of forced) process.stdout.write(`  - ${e.path}  (backup: ${e.path}.orig)\n`);
  }
  if (ctx.notes.length && !ctx.dryRun) {
    process.stdout.write('\nNext steps:\n');
    for (const n of ctx.notes) process.stdout.write(`  - ${n}\n`);
  }
  if (ctx.dryRun) process.stdout.write('\n(dry run — nothing written)\n');
}

function cmdInit(args) {
  const ctx = install.makeContext(args);
  install.migrateLegacyStateRoot(ctx);
  const reinstall = fs.existsSync(path.join(ctx.targetRoot, '.nogging/config.json'));
  if (reinstall && !ctx.dryRun) {
    process.stdout.write(
      'Nogging is already installed here; re-running init idempotently ' +
        '(use `update` for routine refreshes).\n',
    );
  }
  install.initBeads(ctx);
  install.copyVerbatim(ctx);
  install.copyDocs(ctx);
  install.writeScaffold(ctx);
  applyMerges(ctx);
  renderSystemd(ctx);
  install.recordVersion(ctx);
  install.installGitHooks(ctx);
  install.beadsHint(ctx);
  report(ctx);
  install.readinessVerdict(ctx);
}

function cmdUpdate(args) {
  const ctx = install.makeContext(args);
  install.migrateLegacyStateRoot(ctx);
  if (!fs.existsSync(path.join(ctx.targetRoot, '.nogging/config.json'))) {
    throw Object.assign(new Error('no .nogging/config.json — run `init` first'), { userFacing: true });
  }
  install.copyVerbatim(ctx);
  install.copyDocs(ctx);
  install.writeScaffold(ctx, { updating: true });
  applyMerges(ctx);
  renderSystemd(ctx);
  install.recordVersion(ctx);
  install.installGitHooks(ctx);
  report(ctx);
  install.readinessVerdict(ctx);
}

function cmdRemove(args) {
  const ctx = install.makeContext(args);
  removeInstallation(ctx);
  report(ctx);
}

function cmdDoctor() {
  const { spawnSync } = require('child_process');
  if (!fs.existsSync('scripts/nogg')) {
    throw Object.assign(new Error('scripts/nogg not found — run `init` first'), { userFacing: true });
  }
  const r = spawnSync('scripts/nogg', ['doctor'], { stdio: 'inherit' });
  process.exit(r.status == null ? 1 : r.status);
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`nogg: ${e.message}\n`);
    process.exit(2);
  }

  if (args.version) {
    if (args.command && args.command !== 'version') {
      process.stderr.write('nogg: --version cannot be combined with another command\n');
      process.exit(2);
    }
    process.stdout.write(`${VERSION}\n`);
    process.exit(0);
  }

  if (args.help || !args.command) {
    process.stdout.write(USAGE);
    process.exit(args.command ? 0 : (args.help ? 0 : 1));
  }

  try {
    switch (args.command) {
      case 'version': process.stdout.write(`${VERSION}\n`); break;
      case 'init': cmdInit(args); break;
      case 'update': cmdUpdate(args); break;
      case 'remove': cmdRemove(args); break;
      case 'doctor': cmdDoctor(args); break;
      default:
        process.stderr.write(`nogg: unknown command: ${args.command}\n`);
        process.exit(2);
    }
  } catch (e) {
    process.stderr.write(`nogg: ${e.userFacing ? e.message : e.stack || e.message}\n`);
    process.exit(1);
  }
}

main();
