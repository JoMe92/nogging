#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const install = require('./lib/install');
const { applyMerges } = require('./lib/merge');
const { renderSystemd } = require('./lib/systemd');
const { removeInstallation } = require('./lib/remove');
const { runPreflight, bootstrapHint } = require('./lib/preflight');
const reporter = require('./lib/report');
const nextsteps = require('./lib/nextsteps');
const { version: VERSION } = require('../package.json');

const USAGE = `nogg — install the Nogging operating structure into a repo

Usage:
  npx github:JoMe92/nogging#v${VERSION} <command> [options]

Commands:
  version   Print the Nogging package version
  init      Install Nogging into the current git repository
  update    Refresh tool files and re-apply merges; project-owned state is kept
  remove    Remove managed payload while preserving project-owned state
  doctor    Run the installed ./scripts/nogg doctor and print the readiness verdict

Options:
  --dry-run      Show what would change, write nothing
  --force        Overwrite locally modified verbatim files on init/update, keeping a <file>.orig backup
  --no-beads     Skip initializing the Beads issue tracker
  --no-hooks     Skip installing the git hooks
  --no-systemd   Skip rendering the systemd sync unit
  --verbose      List every file under its class (default: counts only)
  -v, --version  Print the Nogging package version
  -h, --help     Show this help

init is idempotent and safe to re-run; use update for routine refreshes.
Guide: docs/installation.md (https://github.com/JoMe92/nogging/blob/v${VERSION}/docs/installation.md)
Fresh machine: ${bootstrapHint(VERSION)}
`;

function parseArgs(argv) {
  const args = { command: null, dryRun: false, force: false, noBeads: false, noHooks: false, noSystemd: false, verbose: false, help: false, version: false };
  for (const a of argv) {
    switch (a) {
      case '-h':
      case '--help': args.help = true; break;
      case '--dry-run': args.dryRun = true; break;
      case '--force': args.force = true; break;
      case '--no-beads': args.noBeads = true; break;
      case '--no-hooks': args.noHooks = true; break;
      case '--no-systemd': args.noSystemd = true; break;
      case '--verbose': args.verbose = true; break;
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

// Ends init, update and remove: the numbered next steps (not on a dry run).
function printNextSteps(ctx, command, gaps) {
  if (ctx.dryRun) return;
  const lines = nextsteps.nextStepsLines(nextsteps.nextStepItems(ctx, command, gaps));
  if (lines.length) process.stdout.write(`\n${lines.join('\n')}\n`);
}

function cmdInit(args) {
  const ctx = install.makeContext(args);
  process.stdout.write(`${reporter.header(ctx, 'init')}\n\n`);
  runPreflight(ctx);
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
  process.stdout.write(reporter.render(ctx));
  const gaps = install.readinessVerdict(ctx);
  printNextSteps(ctx, 'init', gaps);
}

function cmdUpdate(args) {
  const ctx = install.makeContext(args);
  const previousVersion = install.readRecordedVersion(ctx);
  process.stdout.write(`${reporter.header(ctx, 'update', { previousVersion })}\n\n`);
  runPreflight(ctx);
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
  process.stdout.write(reporter.render(ctx));
  const dispatchNotice = install.dispatchDefaultNotice(ctx);
  if (dispatchNotice) process.stdout.write(`\n${dispatchNotice}\n`);
  const testingNotice = install.testingDefaultNotice(ctx);
  if (testingNotice) process.stdout.write(`\n${testingNotice}\n`);
  const gaps = install.readinessVerdict(ctx);
  printNextSteps(ctx, 'update', gaps);
}

function cmdRemove(args) {
  const ctx = install.makeContext(args);
  process.stdout.write(`${reporter.header(ctx, 'remove')}\n\n`);
  removeInstallation(ctx);
  process.stdout.write(reporter.render(ctx));
  printNextSteps(ctx, 'remove', []);
}

// Runs `scripts/nogg doctor` once, prints its report unchanged, then the same
// readiness verdict and the init next steps; exits with doctor's status.
function cmdDoctor() {
  if (!fs.existsSync('scripts/nogg')) {
    throw Object.assign(new Error('scripts/nogg not found — run `init` first'), { userFacing: true });
  }
  const ctx = { targetRoot: process.cwd(), version: VERSION, units: [], review: [], dryRun: false };
  const doctor = nextsteps.runDoctor(ctx.targetRoot);
  process.stdout.write(doctor.stdout);
  process.stderr.write(doctor.stderr);
  const gaps = install.readinessVerdict(ctx, doctor);
  printNextSteps(ctx, 'init', gaps);
  process.exit(doctor.status == null ? 1 : doctor.status);
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
