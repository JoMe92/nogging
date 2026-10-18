'use strict';

// Advisory host check run first by `init` and `update` (also under --dry-run).
// It never changes the exit status, never blocks or alters a write, never
// installs anything and never uses the network. `doctor` stays authoritative.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const DEFAULT_TIMEOUT_MS = 5000;
const AGENT_CLIS = ['claude', 'codex', 'pi', 'agy'];

function bootstrapHint(version) {
  return `curl -fsSL https://raw.githubusercontent.com/JoMe92/nogging/v${version}/scripts/bootstrap | bash`;
}

// One table drives the check. `argv` + `re` read the version (`re` captures
// it); `node` is read from process.versions with no spawn. `min` is "major.minor".
function buildTable(version) {
  const bootstrap = `the pinned bootstrap: ${bootstrapHint(version)}`;
  const trackerHint = `${bootstrap}, or docs/installation.md#prerequisites-in-the-target-repo`;
  return {
    required: [
      { name: 'Node.js', min: '18', node: true,
        hint: `upgrade Node, e.g. via nvm, or run ${bootstrap}` },
      { name: 'Git', cmd: 'git', argv: ['--version'], re: /version (\d+(?:\.\d+)+)/, min: '2.30',
        hint: `sudo apt-get install git, or run ${bootstrap}` },
      { name: 'Bash', cmd: 'bash', argv: ['--version'], re: /version (\d+(?:\.\d+)+)/, min: '4.4',
        hint: 'sudo apt-get install bash' },
      { name: 'Python 3', cmd: 'python3', argv: ['--version'], re: /Python (\d+(?:\.\d+)+)/, min: '3.9',
        hint: 'sudo apt-get install python3' },
      { name: 'OpenSpec CLI', cmd: 'openspec', argv: ['--version'], re: /(\d+\.\d+(?:\.\d+)?)/, min: '1.11',
        hint: 'npm install -g @fission-ai/openspec@1.11' },
      { name: 'bd (Beads)', cmd: 'bd', argv: ['--version'], re: /version (\d+(?:\.\d+)+)/, min: '1.2',
        hint: trackerHint },
      { name: 'Dolt', cmd: 'dolt', argv: ['version'], re: /version (\d+(?:\.\d+)+)/, min: '2.3',
        hint: trackerHint },
    ],
  };
}

function parseVersion(text) {
  return String(text).split('.').map(n => parseInt(n, 10) || 0);
}

function atLeast(found, min) {
  const f = parseVersion(found);
  const m = parseVersion(min);
  for (let i = 0; i < Math.max(f.length, m.length); i++) {
    const d = (f[i] || 0) - (m[i] || 0);
    if (d !== 0) return d > 0;
  }
  return true;
}

// Looks a command up on PATH without running it.
function onPath(cmd, env) {
  for (const dir of String(env.PATH || '').split(path.delimiter)) {
    if (!dir) continue;
    try {
      const full = path.join(dir, cmd);
      if (fs.statSync(full).isFile()) {
        fs.accessSync(full, fs.constants.X_OK);
        return true;
      }
    } catch (_) { /* not here */ }
  }
  return false;
}

function timeoutMs(env) {
  const n = parseInt(env.NOGG_PREFLIGHT_TIMEOUT_MS, 10);
  return n > 0 ? n : DEFAULT_TIMEOUT_MS;
}

// Returns null when the tool passes, else { status, line }.
function probe(row, env, timeout) {
  let found;
  if (row.node) {
    found = process.versions.node;
  } else {
    if (!onPath(row.cmd, env)) {
      return { status: 'MISSING', line: `MISSING ${row.name} (need >= ${row.min}) — fix: ${row.hint}` };
    }
    const r = spawnSync(row.cmd, row.argv, { encoding: 'utf8', timeout, env, stdio: ['ignore', 'pipe', 'pipe'] });
    const m = r.error || r.status !== 0 ? null : row.re.exec(`${r.stdout || ''}\n${r.stderr || ''}`);
    if (!m) {
      const why = r.error && r.error.code === 'ETIMEDOUT' ? `no answer within ${timeout} ms` : 'version unreadable';
      return { status: 'UNKNOWN', line: `UNKNOWN ${row.name} (${why}; need >= ${row.min}) — fix: ${row.hint}` };
    }
    found = m[1];
  }
  if (atLeast(found, row.min)) return null;
  return { status: 'TOO OLD', line: `TOO OLD ${row.name} (${found} < ${row.min}) — fix: ${row.hint}` };
}

// Pure check: returns { ok, total, problems, optional, warnings } without printing.
function checkHost(ctx, env = process.env) {
  const table = buildTable(ctx.version);
  const timeout = timeoutMs(env);
  const problems = table.required
    .map(row => probe(row, env, timeout))
    .filter(Boolean);
  const optional = [];
  const warnings = [];

  const mux = ['tmux', 'herdr'].filter(c => onPath(c, env));
  if (mux.length) optional.push(...mux);
  else warnings.push('WARN tmux or herdr not found — fix: sudo apt-get install tmux; needed for supervised sessions');

  if (!ctx.noSystemd) {
    if (onPath('systemctl', env)) optional.push('systemd');
    else warnings.push('WARN systemd user services not found — fix: needed only for the sync timer and orchestrator service; pass --no-systemd to skip');
  }

  const agents = AGENT_CLIS.filter(c => onPath(c, env));
  if (agents.length) optional.push(...agents);
  else {
    warnings.push(
      `WARN no agent CLI found (${AGENT_CLIS.join(', ')}) — fix: install at least one agent; see docs/compatibility.md`,
    );
  }

  return { total: table.required.length, problems, optional, warnings };
}

function runPreflight(ctx, { env = process.env, out = process.stdout } = {}) {
  let r;
  try {
    r = checkHost(ctx, env);
  } catch (e) {
    // Advisory only: a probe bug must never stop an install.
    out.write(`Preflight: skipped (${e.message})\n\n`);
    return null;
  }
  const passed = r.total - r.problems.length;
  const optional = r.optional.length ? `; optional: ${r.optional.join(', ')}` : '';
  if (r.problems.length === 0) {
    out.write(`Preflight: ${passed}/${r.total} required tools OK${optional}\n`);
  } else {
    out.write(`Preflight: ${passed}/${r.total} required tools OK; ${r.problems.length} need attention${optional}\n`);
    for (const p of r.problems) out.write(`  ${p.line}\n`);
  }
  for (const w of r.warnings) out.write(`  ${w}\n`);
  out.write('\n');
  return r;
}

module.exports = { runPreflight, checkHost, buildTable, bootstrapHint, atLeast };
