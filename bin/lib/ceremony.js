'use strict';

// The lean install (adaptive-ceremony, design Decision 7): when the target's
// `ceremony.mode` is not `always-full`, the marker merge writes the lean block
// pair and the Nogging skills; under the default nothing here writes anything.

const fs = require('fs');
const path = require('path');

const manifest = require('./manifest');
const fsops = require('./fsops');
const manifestStore = require('./manifest-store');

const DEFAULT_MODE = 'always-full';
const MODES = [DEFAULT_MODE, 'adaptive', 'always-fast'];

// The installer's one read of the target's `ceremony.mode`. Values and fall-back
// follow design Decision 1: an absent block, an unreadable file or an unknown
// mode is the default. `doctor` warns about a bad value, not the installer.
// Point this at the shared reader (`nogg ceremony`) once it ships with the package.
function targetMode(ctx) {
  let data;
  try {
    data = JSON.parse(fsops.readTarget('.nogging/config.json', ctx));
  } catch (_) {
    return DEFAULT_MODE;
  }
  const block = data && typeof data === 'object' ? data.ceremony : null;
  const mode = block && typeof block === 'object' && !Array.isArray(block) ? block.mode : null;
  return MODES.includes(mode) ? mode : DEFAULT_MODE;
}

function isLean(ctx) {
  return targetMode(ctx) !== DEFAULT_MODE;
}

// The block templates for the mode: { 'CLAUDE.md': <template>, 'AGENTS.md': <template> }.
function blockTemplates(ctx) {
  return manifest.ceremony.blocks[isLean(ctx) ? 'lean' : 'full'];
}

// Every skill file of the one source, as { src, rels }: one destination per skill root.
function skillFiles(pkgRoot) {
  const out = [];
  const walk = (abs, rel) => {
    for (const entry of fs.readdirSync(abs, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const childAbs = path.join(abs, entry.name);
      const childRel = path.posix.join(rel, entry.name);
      if (entry.isDirectory()) walk(childAbs, childRel);
      else if (entry.isFile()) {
        out.push({ src: childAbs, rels: manifest.ceremony.skillRoots.map((root) => path.posix.join(root, childRel)) });
      }
    }
  };
  walk(path.join(pkgRoot, manifest.ceremony.skillsFrom), '');
  return out;
}

// Remove one installed skill file. A file the operator edited is kept and named.
function removeSkill(ctx, rel, srcAbs) {
  const abs = path.join(ctx.targetRoot, rel);
  if (!fs.existsSync(abs)) {
    if (ctx.nextInstalledManifest) delete ctx.nextInstalledManifest.files[rel];
    return;
  }
  const cur = manifestStore.sha256(fs.readFileSync(abs));
  const known = [manifestStore.getRecordedDigest(ctx.installedManifest, rel), manifestStore.hashFile(srcAbs)];
  if (!known.includes(cur) && !ctx.force) {
    ctx.log.add('keep', rel, 'locally modified');
    ctx.warnings.push(`${rel} was edited locally and is kept; delete it yourself (ceremony.mode is ${DEFAULT_MODE}).`);
    return;
  }
  if (!ctx.dryRun) {
    fs.rmSync(abs, { force: true });
    fs.rmSync(`${abs}.nogging-new`, { force: true });
    // The skill's directory, then the skill root: each only when it is left empty.
    for (const dir of [path.dirname(abs), path.dirname(path.dirname(abs))]) {
      try { fs.rmdirSync(dir); } catch (_) { break; }
    }
  }
  if (ctx.nextInstalledManifest) delete ctx.nextInstalledManifest.files[rel];
  ctx.log.add('remove', rel, ctx.dryRun ? 'dry-run' : undefined);
}

// Install the skills under a lean mode and remove them under the default, so a
// mode change takes effect at the next `update`, both ways.
function syncSkills(ctx) {
  const lean = isLean(ctx);
  ctx.log.setClass('agents');
  for (const file of skillFiles(ctx.pkgRoot)) {
    for (const rel of file.rels) {
      if (lean) fsops.copyFile(file.src, rel, ctx);
      else removeSkill(ctx, rel, file.src);
    }
  }
}

module.exports = { DEFAULT_MODE, MODES, targetMode, isLean, blockTemplates, skillFiles, syncSkills };
