'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const baselines = require('./baselines');

const MANIFEST_REL_PATH = '.nogging/installed-manifest.json';
const CURRENT_MANIFEST_VERSION = 1;

/**
 * Compute lowercase SHA-256 hex digest of a Buffer or string.
 */
function sha256(content) {
  if (content == null) {
    throw new TypeError('content cannot be null or undefined');
  }
  return crypto.createHash('sha256').update(content).digest('hex');
}

/**
 * Read a file from disk and compute its SHA-256 digest.
 * Returns null if the file does not exist.
 */
function hashFile(absPath) {
  try {
    if (!fs.existsSync(absPath)) return null;
    const stat = fs.statSync(absPath);
    if (!stat.isFile()) return null;
    const buf = fs.readFileSync(absPath);
    return sha256(buf);
  } catch (_) {
    return null;
  }
}

/**
 * Return a new object with keys sorted alphabetically.
 */
function sortObjectKeys(obj) {
  const sorted = {};
  if (!obj || typeof obj !== 'object') return sorted;
  for (const k of Object.keys(obj).sort()) {
    sorted[k] = obj[k];
  }
  return sorted;
}

/**
 * Validate manifest structure.
 */
function validateManifest(manifestObj) {
  if (!manifestObj || typeof manifestObj !== 'object') {
    throw new Error('manifest must be an object');
  }
  if (!Number.isInteger(manifestObj.manifest_version) || manifestObj.manifest_version < 1) {
    throw new Error('manifest_version must be a positive integer');
  }
  if (typeof manifestObj.nogging_version !== 'string' || manifestObj.nogging_version.trim() === '') {
    throw new Error('nogging_version must be a non-empty string');
  }
  if (!manifestObj.files || typeof manifestObj.files !== 'object' || Array.isArray(manifestObj.files)) {
    throw new Error('manifest files must be a dictionary object');
  }
  for (const [relPath, digest] of Object.entries(manifestObj.files)) {
    if (typeof relPath !== 'string' || relPath.trim() === '') {
      throw new Error(`invalid manifest file path key: ${relPath}`);
    }
    if (typeof digest !== 'string' || !/^[0-9a-f]{64}$/i.test(digest)) {
      throw new Error(`invalid SHA-256 digest for ${relPath}: ${digest}`);
    }
  }
  return true;
}

/**
 * Serialize a manifest object into deterministic pretty JSON.
 */
function serializeManifest(manifestObj) {
  validateManifest(manifestObj);
  const normalized = {
    manifest_version: manifestObj.manifest_version,
    nogging_version: manifestObj.nogging_version,
    files: sortObjectKeys(manifestObj.files),
  };
  return JSON.stringify(normalized, null, 2) + '\n';
}

/**
 * Parse and validate manifest JSON.
 */
function parseManifest(rawJson) {
  let parsed;
  try {
    parsed = JSON.parse(rawJson);
  } catch (err) {
    throw new Error(`failed to parse manifest JSON: ${err.message}`);
  }
  validateManifest(parsed);
  return {
    manifest_version: parsed.manifest_version,
    nogging_version: parsed.nogging_version,
    files: sortObjectKeys(parsed.files),
  };
}

/**
 * Collect all verbatim, directory, and documentation files defined in the manifest.
 * Returns a dictionary mapping repo-relative POSIX destination path to absolute source path.
 */
function collectPackageFiles(pkgRoot, manifestDef) {
  const def = manifestDef || require('./manifest');
  const fileMap = {};

  // 1. Verbatim files
  if (Array.isArray(def.verbatim)) {
    for (const rel of def.verbatim) {
      const absSrc = path.join(pkgRoot, rel);
      fileMap[rel.split(path.sep).join('/')] = absSrc;
    }
  }

  // 2. Verbatim directories
  function walkDir(srcAbsDir, destRelPrefix) {
    if (!fs.existsSync(srcAbsDir)) return;
    for (const entry of fs.readdirSync(srcAbsDir, { withFileTypes: true })) {
      const childSrc = path.join(srcAbsDir, entry.name);
      const childDest = path.posix.join(destRelPrefix, entry.name);
      if (entry.isDirectory()) {
        walkDir(childSrc, childDest);
      } else if (entry.isFile()) {
        fileMap[childDest] = childSrc;
      }
    }
  }

  if (Array.isArray(def.verbatimDirs)) {
    for (const dir of def.verbatimDirs) {
      walkDir(path.join(pkgRoot, dir.from), dir.to);
    }
  }

  // 3. Documentation files
  if (Array.isArray(def.docs)) {
    for (const doc of def.docs) {
      fileMap[doc.to.split(path.sep).join('/')] = path.join(pkgRoot, doc.from);
    }
  }

  return sortObjectKeys(fileMap);
}

/**
 * Compute the complete manifest for the current package.
 */
function computePackageManifest(pkgRoot, version, manifestDef) {
  const collected = collectPackageFiles(pkgRoot, manifestDef);
  const files = {};

  for (const [destRel, srcAbs] of Object.entries(collected)) {
    const digest = hashFile(srcAbs);
    if (digest == null) {
      throw new Error(`missing source file for verbatim manifest: ${srcAbs} (${destRel})`);
    }
    files[destRel] = digest;
  }

  return {
    manifest_version: CURRENT_MANIFEST_VERSION,
    nogging_version: version || '0.0.0',
    files: sortObjectKeys(files),
  };
}

/**
 * Read the installed manifest from a target repository root.
 * Returns null if the manifest does not exist or is invalid.
 */
function readManifest(targetRoot) {
  const manifestAbs = path.join(targetRoot, MANIFEST_REL_PATH);
  if (!fs.existsSync(manifestAbs)) return null;
  try {
    const raw = fs.readFileSync(manifestAbs, 'utf8');
    return parseManifest(raw);
  } catch (_) {
    return null;
  }
}

/**
 * Write the manifest to .nogging/installed-manifest.json in targetRoot.
 */
function writeManifest(targetRoot, manifestObj, { dryRun = false } = {}) {
  const content = serializeManifest(manifestObj);
  const manifestAbs = path.join(targetRoot, MANIFEST_REL_PATH);
  if (!dryRun) {
    const dir = path.dirname(manifestAbs);
    if (!fs.existsSync(dir)) {
      fs.mkdirSync(dir, { recursive: true });
    }
    fs.writeFileSync(manifestAbs, content);
  }
  return content;
}

/**
 * Get recorded digest from an in-memory manifest object.
 */
function getRecordedDigest(manifestObj, relPath) {
  if (!manifestObj || !manifestObj.files) return null;
  const posixPath = relPath.split(path.sep).join('/');
  return manifestObj.files[posixPath] || null;
}

/**
 * Resolve the recorded baseline hash for a file.
 * Prioritizes:
 * 1. Existing in-memory manifestObj (or on disk in targetRoot if manifestObj is null).
 * 2. Bundled release baselines (including matching against recordedVersion and historical releases).
 */
function resolveRecordedDigest({ targetRoot, manifestObj, relPath, recordedVersion, curDigest }) {
  const posixPath = relPath.split(path.sep).join('/');
  let manifest = manifestObj;
  if (!manifest && targetRoot) {
    manifest = readManifest(targetRoot);
  }
  const manifestDigest = getRecordedDigest(manifest, posixPath);
  if (manifestDigest) {
    return manifestDigest;
  }

  return baselines.resolveBaselineHash(posixPath, recordedVersion, curDigest);
}

/**
 * Pure 3-way evaluation helper:
 * Returns: 'create' | 'unchanged' | 'update' | 'preserve'
 */
function evaluateFileState({ curDigest, nextDigest, recordedDigest }) {
  if (!curDigest) return 'create';
  if (curDigest === nextDigest) return 'unchanged';
  if (recordedDigest && curDigest === recordedDigest) return 'update';
  return 'preserve';
}

module.exports = {
  MANIFEST_REL_PATH,
  CURRENT_MANIFEST_VERSION,
  sha256,
  hashFile,
  sortObjectKeys,
  validateManifest,
  serializeManifest,
  parseManifest,
  collectPackageFiles,
  computePackageManifest,
  readManifest,
  writeManifest,
  getRecordedDigest,
  resolveRecordedDigest,
  evaluateFileState,
};
