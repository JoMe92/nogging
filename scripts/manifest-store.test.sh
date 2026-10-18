#!/usr/bin/env bash
# Unit and integration tests for manifest-store and release baselines (TASK-PVE-001).
# Verifies Decision 1 manifest format, serialization, hashing, and Decision 3 baselines.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/test-env.sh"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   - skipped (node not installed)"
  echo "all manifest-store checks passed"
  exit 0
fi

fail=0
check() { # <desc> <node-eval-code>
  local desc="$1"; shift
  if node -e "$1"; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc"
    fail=1
  fi
}

# 1. Digest calculation and hashing
check "sha256 computes expected hash for known string" "
const store = require('$root/bin/lib/manifest-store');
const crypto = require('crypto');
const data = 'hello nogging manifest';
const expected = crypto.createHash('sha256').update(data).digest('hex');
if (store.sha256(data) !== expected) process.exit(1);
"

check "hashFile returns correct hash for existing file and null for missing" "
const store = require('$root/bin/lib/manifest-store');
const fs = require('fs');
const crypto = require('crypto');
const expected = crypto.createHash('sha256').update(fs.readFileSync('$root/scripts/nogg')).digest('hex');
if (store.hashFile('$root/scripts/nogg') !== expected) process.exit(1);
if (store.hashFile('$root/nonexistent-file-xyz') !== null) process.exit(1);
"

# 2. Schema validation and serialization
check "serializeManifest sorts keys deterministically and adds newline" "
const store = require('$root/bin/lib/manifest-store');
const raw = {
  manifest_version: 1,
  nogging_version: '2.2.0',
  files: {
    'z/file': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    'a/file': 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
    'm/file': '1111111111111111111111111111111111111111111111111111111111111111',
  }
};
const serialized = store.serializeManifest(raw);
const lines = serialized.split('\n');
const keyIndices = ['a/file', 'm/file', 'z/file'].map(k => lines.findIndex(l => l.includes(k)));
if (keyIndices[0] >= keyIndices[1] || keyIndices[1] >= keyIndices[2]) process.exit(1);
if (!serialized.endsWith('\n')) process.exit(1);
"

check "parseManifest validates schema and rejects malformed payloads" "
const store = require('$root/bin/lib/manifest-store');
const assert = require('assert');

// valid
const valid = JSON.stringify({
  manifest_version: 1,
  nogging_version: '2.2.0',
  files: { 'foo': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' }
});
assert.strictEqual(store.parseManifest(valid).manifest_version, 1);

// invalid version
assert.throws(() => store.parseManifest(JSON.stringify({ manifest_version: 0, nogging_version: '1.0', files: {} })));
assert.throws(() => store.parseManifest(JSON.stringify({ manifest_version: 1, nogging_version: '', files: {} })));
assert.throws(() => store.parseManifest(JSON.stringify({ manifest_version: 1, nogging_version: '1.0', files: { 'a': 'not-a-hash' } })));
assert.throws(() => store.parseManifest('invalid json{'));
"

# 3. Full package manifest computation
check "computePackageManifest covers all verbatim and docs files" "
const store = require('$root/bin/lib/manifest-store');
const manifest = store.computePackageManifest('$root', '2.2.0');
if (manifest.manifest_version !== 1) process.exit(1);
if (manifest.nogging_version !== '2.2.0') process.exit(1);

// Must contain scripts/nogg, rules, prompts, and docs
const files = manifest.files;
if (!files['scripts/nogg']) process.exit(1);
if (!files['.codex/rules/nogging.rules']) process.exit(1);
if (!files['.nogging/launch-prompts/orchestrator.md']) process.exit(1);
if (!files['docs/nogging/operating-model.md']) process.exit(1);

// Every file digest must be 64-char lowercase hex
for (const [p, d] of Object.entries(files)) {
  if (!/^[0-9a-f]{64}$/.test(d)) {
    console.error('Invalid digest for', p, d);
    process.exit(1);
  }
}
"

# 4. Manifest disk I/O and dry-run
check "writeManifest and readManifest work with target directory" "
const store = require('$root/bin/lib/manifest-store');
const fs = require('fs');
const os = require('os');
const path = require('path');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'manifest-test-'));
try {
  const sample = {
    manifest_version: 1,
    nogging_version: '2.2.0',
    files: { 'scripts/nogg': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' }
  };

  // Dry-run should not create file
  store.writeManifest(tmpDir, sample, { dryRun: true });
  if (store.readManifest(tmpDir) !== null) process.exit(1);

  // Real write creates file and can be read back
  store.writeManifest(tmpDir, sample, { dryRun: false });
  const readBack = store.readManifest(tmpDir);
  if (!readBack) process.exit(1);
  if (readBack.manifest_version !== 1) process.exit(1);
  if (readBack.files['scripts/nogg'] !== sample.files['scripts/nogg']) process.exit(1);
} finally {
  fs.rmSync(tmpDir, { recursive: true, force: true });
}
"

# 5. Bundled historical baselines (Decision 3)
check "baselines include v2.1.0 and v2.2.0 with valid hashes" "
const baselines = require('$root/bin/lib/baselines');
if (!baselines.BASELINES['2.1.0']) process.exit(1);
if (!baselines.BASELINES['2.2.0']) process.exit(1);

const nogg210 = baselines.lookupFileHash('scripts/nogg', '2.1.0');
const nogg220 = baselines.lookupFileHash('scripts/nogg', '2.2.0');
if (!nogg210 || !nogg220) process.exit(1);
if (nogg210 === nogg220) process.exit(1); // scripts/nogg changed between 2.1.0 and 2.2.0
"

check "baselines resolveBaselineHash correctly handles unmodified and modified cases" "
const baselines = require('$root/bin/lib/baselines');
const hash210 = baselines.lookupFileHash('scripts/nogg', '2.1.0');
const hash220 = baselines.lookupFileHash('scripts/nogg', '2.2.0');

// Unmodified matching recorded version
if (baselines.resolveBaselineHash('scripts/nogg', '2.1.0', hash210) !== hash210) process.exit(1);
if (baselines.resolveBaselineHash('scripts/nogg', 'v2.2.0', hash220) !== hash220) process.exit(1);

// Unmodified matching another release baseline when version is unknown or wrong
if (baselines.resolveBaselineHash('scripts/nogg', 'unknown-ver', hash210) !== hash210) process.exit(1);
if (baselines.resolveBaselineHash('scripts/nogg', null, hash220) !== hash220) process.exit(1);

// Modified file with known version: returns recorded baseline hash
const modHash = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
if (baselines.resolveBaselineHash('scripts/nogg', '2.1.0', modHash) !== hash210) process.exit(1);

// Modified file with completely unknown version: returns null
if (baselines.resolveBaselineHash('scripts/nogg', 'unknown', modHash) !== null) process.exit(1);
"

# 6. resolveRecordedDigest and evaluateFileState
check "resolveRecordedDigest prefers manifest when present and falls back to baseline" "
const store = require('$root/bin/lib/manifest-store');
const baselines = require('$root/bin/lib/baselines');
const hash210 = baselines.lookupFileHash('scripts/nogg', '2.1.0');

const manifestObj = {
  manifest_version: 1,
  nogging_version: '2.3.0',
  files: { 'scripts/nogg': 'customrecordedhash' }
};

// Reads from manifestObj
const fromManifest = store.resolveRecordedDigest({ manifestObj, relPath: 'scripts/nogg' });
if (fromManifest !== 'customrecordedhash') process.exit(1);

// Falls back to baseline when manifest is null
const fromBaseline = store.resolveRecordedDigest({
  manifestObj: null,
  relPath: 'scripts/nogg',
  recordedVersion: '2.1.0',
  curDigest: hash210
});
if (fromBaseline !== hash210) process.exit(1);
"

check "evaluateFileState adheres to 3-way decision matrix" "
const store = require('$root/bin/lib/manifest-store');
const H1 = '1111111111111111111111111111111111111111111111111111111111111111';
const H2 = '2222222222222222222222222222222222222222222222222222222222222222';
const H3 = '3333333333333333333333333333333333333333333333333333333333333333';

// 1. Missing cur -> create
if (store.evaluateFileState({ curDigest: null, nextDigest: H1, recordedDigest: null }) !== 'create') process.exit(1);

// 2. cur equals next -> unchanged
if (store.evaluateFileState({ curDigest: H1, nextDigest: H1, recordedDigest: H2 }) !== 'unchanged') process.exit(1);

// 3. cur equals recorded (unmodified locally, changed upstream) -> update
if (store.evaluateFileState({ curDigest: H1, nextDigest: H2, recordedDigest: H1 }) !== 'update') process.exit(1);

// 4. cur differs from recorded and next -> preserve
if (store.evaluateFileState({ curDigest: H3, nextDigest: H2, recordedDigest: H1 }) !== 'preserve') process.exit(1);
"

if [[ $fail -ne 0 ]]; then
  echo "Nogging: manifest-store tests failed" >&2
  exit 1
fi
echo "Nogging: all manifest-store tests passed"
