#!/usr/bin/env bash
# Exercises .pi/extensions/specforge-guard.ts's matching logic directly,
# without a live `pi` process: every SpecForge command-floor pattern gets
# both an ALLOW and a BLOCK example, and the openspec/ write-boundary
# predicates (isUnderOpenspec, openspecBoundaryOpen) get exercised against a
# throwaway fixture directory.
#
# Node is required to load a TypeScript ESM module, and needs sufficiently
# modern type-stripping support (Node 22.6+ default-on, 22.18+ stable) to do
# so directly. This repo's test suite is otherwise bash + coreutils only,
# offline (see scripts/test's own header). When node is absent, or present
# but unable to load specforge-guard.ts directly (e.g. too old for
# TypeScript type-stripping), this test skips with a PASS rather than
# failing the suite, matching scripts/cli.test.sh.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
guard="$root/.pi/extensions/specforge-guard.ts"

if ! command -v node >/dev/null 2>&1; then
  echo "ok   - skipped (node not installed)"
  echo "all pi-guard checks passed"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

runner="$work/pi-guard-runner.mjs"
cat > "$runner" <<'NODE'
import { pathToFileURL } from "node:url";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const guardPath = process.argv[2];

// First step: attempt the dynamic import. Any failure here (old Node that
// can't strip TypeScript syntax, a syntax error, whatever) is treated as
// "this Node can't run this test" rather than a real failure — the caller
// distinguishes this via the exit code (2).
let mod;
try {
  mod = await import(pathToFileURL(guardPath).href);
} catch (e) {
  console.log("IMPORT_FAILED: " + (e && e.message ? e.message : e));
  process.exit(2);
}

const { matchesFloor, isUnderOpenspec, openspecBoundaryOpen } = mod;

let fail = 0;
function check(desc, cond) {
  if (cond) {
    console.log(`ok   - ${desc}`);
  } else {
    console.log(`FAIL - ${desc}`);
    fail = 1;
  }
}

function blocked(name, cmd) {
  check(`${name}: blocks ${JSON.stringify(cmd)}`, matchesFloor(cmd) === name);
}
function allowed(name, cmd) {
  check(`${name}: allows ${JSON.stringify(cmd)}`, matchesFloor(cmd) === undefined);
}

blocked("sudo", "sudo apt install x");
allowed("sudo", "apt install x");

blocked("rm -rf/-fr", "rm -rf /tmp/x");
blocked("rm -rf/-fr", "rm -fr /tmp/x");
allowed("rm -rf/-fr", "rm -r /tmp/x");
allowed("rm -rf/-fr", "rm /tmp/x");

blocked("dd", "dd if=/dev/zero of=/dev/sda");
allowed("dd", "echo hello");

blocked("mkfs", "mkfs.ext4 /dev/sda1");
blocked("mkfs", "mkfs /dev/sda1");
allowed("mkfs", "echo mkfsomething");
allowed("mkfs", "ls -la");

blocked("shutdown", "shutdown -h now");
allowed("shutdown", "echo hello");

blocked("reboot", "reboot");
allowed("reboot", "echo hello");

blocked("systemctl", "systemctl restart nginx");
allowed("systemctl", "echo hello");

blocked("chown", "chown root file");
allowed("chown", "echo hello");

blocked("curl", "curl https://example.com");
allowed("curl", "echo hello");

blocked("wget", "wget https://example.com");
allowed("wget", "echo hello");

blocked("git push --force", "git push --force");
blocked("git push --force", "git push -f origin main");
blocked("git push --force", "git push --force-with-lease");
allowed("git push --force", "git push origin main");

blocked("git reset --hard", "git reset --hard HEAD~1");
allowed("git reset --hard", "git reset HEAD~1");

blocked("git clean -f", "git clean -fdx");
blocked("git clean -f", "git clean -f");
allowed("git clean -f", "git clean -n");

blocked("git filter-branch", "git filter-branch --force");
allowed("git filter-branch", "echo hello");

// --- openspec/ write-boundary predicates, against a throwaway fixture dir --
const fixture = mkdtempSync(path.join(tmpdir(), "pi-guard-fixture-"));

check(
  "isUnderOpenspec: openspec/changes/foo/tasks.md -> true",
  isUnderOpenspec("openspec/changes/foo/tasks.md", fixture) === true,
);
check(
  "isUnderOpenspec: docs/foo.md -> false",
  isUnderOpenspec("docs/foo.md", fixture) === false,
);
check(
  "isUnderOpenspec: bare openspec directory itself -> true",
  isUnderOpenspec("openspec", fixture) === true,
);

check(
  "openspecBoundaryOpen: open when no lock file is present",
  openspecBoundaryOpen(fixture) === true,
);

mkdirSync(path.join(fixture, ".specforge", "locks"), { recursive: true });
writeFileSync(path.join(fixture, ".specforge", "locks", "openspec.readonly"), "");

check(
  "openspecBoundaryOpen: closed once the lock file exists",
  openspecBoundaryOpen(fixture) === false,
);

rmSync(fixture, { recursive: true, force: true });

process.exit(fail);
NODE

set +e
out=$(node "$runner" "$guard" 2>"$work/stderr")
rc=$?
set -e

if [[ $rc -eq 2 ]]; then
  echo "ok   - skipped (node present but cannot load specforge-guard.ts directly, e.g. too old for TypeScript type-stripping)"
  echo "all pi-guard checks passed"
  exit 0
fi

echo "$out"

if [[ $rc -ne 0 ]]; then
  cat "$work/stderr" >&2
  echo "pi-guard checks failed" >&2
  exit 1
fi

echo "all pi-guard checks passed"
