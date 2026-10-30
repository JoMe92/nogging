'use strict';

// The readiness verdict and the numbered next-steps block that end `init`,
// `update`, `remove` and the installer's `doctor` command. The verdict keeps
// its two first-line shapes (`Nogging is ready — …` and `Nogging is installed
// but not ready: <gap>; <gap>`); no later line repeats those prefixes.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const { buildTable } = require('./preflight');

const TRACKER_GAP = 'uninitialized tracker (run `bd init`)';
const PLAN_COMMAND = './scripts/nogg worktree plan <planning-id> <description>';
const DEFAULT_PROBE_TIMEOUT_MS = 3000;

function quickGuide(version) {
  return `https://github.com/JoMe92/nogging/blob/v${version}/README.md#quick-guide`;
}

// Runs the installed `scripts/nogg doctor` once and captures its output.
// Returns { present, error, status, stdout, stderr }.
function runDoctor(targetRoot) {
  if (!fs.existsSync(path.join(targetRoot, 'scripts', 'nogg'))) {
    return { present: false, error: null, status: null, stdout: '', stderr: '' };
  }
  const r = spawnSync('scripts/nogg', ['doctor'], { cwd: targetRoot, encoding: 'utf8' });
  return {
    present: true,
    error: r.error || null,
    status: r.status,
    stdout: r.stdout || '',
    stderr: r.stderr || '',
  };
}

// Fix hints for the tools `doctor` checks by presence, taken from the
// preflight table so the two never drift apart.
function toolHints(version) {
  const byCmd = {};
  for (const row of buildTable(version).required) if (row.cmd) byCmd[row.cmd] = row.hint;
  return byCmd;
}

// A FAIL text, reduced to a gap and its fix line. Internal command lines
// (e.g. the `bd list …` probe) never reach the operator.
function normalizeFail(text, hints) {
  const raw = text.trim();
  if (/no beads database/i.test(raw)) return { gap: TRACKER_GAP, fix: 'run `bd init` in this repository' };
  if (/^[A-Za-z0-9._-]+$/.test(raw)) {
    const hint = hints[raw];
    return {
      gap: `${raw} not found`,
      fix: hint ? `install ${raw} — ${hint}` : `install ${raw}, then run ./scripts/nogg doctor`,
    };
  }
  let clause = raw.replace(/^(bd|git|dolt|openspec|python3?|scripts\/nogg)\s[^:]*:\s*/, '');
  clause = clause.replace(/^Error:\s*/i, '').split(/;| — /)[0].trim() || raw;
  return { gap: clause, fix: 'run ./scripts/nogg doctor for the details' };
}

// All gaps, deduplicated, each with its fix line. `doctor` is the captured
// result of runDoctor().
function collectGaps(ctx, doctor) {
  const hints = toolHints(ctx.version);
  const gaps = [];
  if (!fs.existsSync(path.join(ctx.targetRoot, '.beads'))) {
    gaps.push({ gap: TRACKER_GAP, fix: 'run `bd init` in this repository' });
  }
  if (!doctor.present) {
    gaps.push({ gap: 'scripts/nogg missing', fix: 're-run `init` to restore the tool scripts' });
  } else if (doctor.error) {
    gaps.push({ gap: 'scripts/nogg doctor could not run', fix: 'run ./scripts/nogg doctor yourself and read its error' });
  } else {
    let sawFail = false;
    for (const line of `${doctor.stdout}\n${doctor.stderr}`.split('\n')) {
      const m = line.match(/^FAIL\s+(.+)$/);
      if (!m) continue;
      sawFail = true;
      gaps.push(normalizeFail(m[1], hints));
    }
    if (!sawFail && doctor.status) {
      gaps.push({ gap: 'scripts/nogg doctor reported problems', fix: 'run ./scripts/nogg doctor for the details' });
    }
  }
  const seen = new Set();
  return gaps.filter((g) => (seen.has(g.gap) ? false : (seen.add(g.gap), true)));
}

// The verdict block: one verdict line, then one `fix:` line per gap.
function verdictLines(gaps) {
  if (gaps.length === 0) {
    return [`Nogging is ready — start your first plan with /plan or ${PLAN_COMMAND}.`];
  }
  return [
    `Nogging is installed but not ready: ${gaps.map((g) => g.gap).join('; ')}`,
    ...gaps.map((g) => `  fix: ${g.fix}`),
  ];
}

function probeTimeout(env) {
  const n = parseInt(env.NOGG_PREFLIGHT_TIMEOUT_MS, 10);
  return n > 0 ? n : DEFAULT_PROBE_TIMEOUT_MS;
}

// Best effort `systemctl --user is-enabled <unit>`: 'enabled', 'disabled' or
// 'unknown' (no systemctl, a timeout, no user bus, any other answer).
function unitState(name, env = process.env) {
  const r = spawnSync('systemctl', ['--user', 'is-enabled', name], {
    encoding: 'utf8',
    timeout: probeTimeout(env),
    env,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  if (r.error) return 'unknown';
  const out = (r.stdout || '').trim();
  if (r.status === 0 && (out === 'enabled' || out === 'enabled-runtime')) return 'enabled';
  if (out === 'disabled') return 'disabled';
  return 'unknown';
}

function enableHint(unit, state) {
  const suffix = state === 'unknown' ? ' if not already enabled' : '';
  if (unit.kind === 'timer') {
    const label = path.basename(unit.rel).startsWith('nogg-loops-') ? 'loop scheduler timer' : 'sync timer';
    return `Enable the ${label}${suffix}: \`systemctl --user enable --now "$PWD/${unit.rel}"\``;
  }
  return `Enable the always-on Orchestration Agent${suffix}: ` +
    `\`systemctl --user enable --now "$PWD/${unit.rel}"\` and ` +
    `\`loginctl enable-linger ${process.env.USER || '<user>'}\` so it starts at boot without a login`;
}

// Returns the next-steps items as [{ text, optional }], required ones first.
// `command` is init | update | remove; `gaps` the verdict gaps (init/update).
function nextStepItems(ctx, command, gaps = [], env = process.env) {
  const required = [];
  const optional = [];
  const trackerGap = gaps.some((g) => g.gap === TRACKER_GAP);
  const resolve = () => {
    if (gaps.length === 0) return;
    required.push(`Resolve each gap above, following its fix line${trackerGap ? ' (`bd init` for the tracker)' : ''}.`);
  };
  const doctorItem = 'Check the installation: `./scripts/nogg doctor`';

  if (command === 'init') {
    resolve();
    required.push(doctorItem);
    required.push(
      `Start your first plan: \`/plan\` in Claude Code, or \`${PLAN_COMMAND}\`. ` +
        `Quick Guide: ${quickGuide(ctx.version)}`,
    );
    for (const unit of ctx.units) optional.push(enableHint(unit, 'disabled'));
  } else if (command === 'update') {
    const preserved = new Set((ctx.review || []).filter((r) => r.kind === 'preserve').map((r) => r.path));
    if (preserved.size > 0) {
      required.push(`Review each .nogging-new file (${preserved.size}), merge what you want, then delete it.`);
    }
    resolve();
    required.push(doctorItem);
    for (const unit of ctx.units) {
      const state = unitState(path.basename(unit.rel), env);
      if (state !== 'enabled') optional.push(enableHint(unit, state));
    }
  } else {
    for (const unit of ctx.units) {
      required.push(`Disable ${path.basename(unit.rel)} before the checkout is moved or deleted: ` +
        `\`systemctl --user disable --now ${path.basename(unit.rel)}\``);
    }
    required.push('Review the shared .gitignore entries and the Git hooks left behind; ownership cannot be inferred safely.');
    required.push('Commit the removal.');
  }
  return [
    ...required.map((text) => ({ text, optional: false })),
    ...optional.map((text) => ({ text, optional: true })),
  ];
}

function nextStepsLines(items) {
  if (items.length === 0) return [];
  return ['Next steps', ...items.map((it, i) => `  ${i + 1}. ${it.text}${it.optional ? ' (optional)' : ''}`)];
}

module.exports = {
  TRACKER_GAP,
  runDoctor,
  collectGaps,
  verdictLines,
  nextStepItems,
  nextStepsLines,
  normalizeFail,
};
