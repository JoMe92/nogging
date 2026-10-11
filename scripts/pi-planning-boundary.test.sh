#!/usr/bin/env bash
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v node >/dev/null || ! node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22 || (a===22 && b>=19)?0:1)'; then
  printf 'SKIP: Pi planning guard needs supported Node type stripping\n'
  exit 0
fi
node --input-type=module - "$root" <<'NODE'
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync, chmodSync, renameSync, symlinkSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir, hostname } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const mod = await import(pathToFileURL(join(source, ".pi/extensions/nogging-guard.ts")).href);
const { openspecBoundaryOpen } = mod;
const scratch = mkdtempSync(join(tmpdir(), "nogg Pi boundary "));
const main = join(scratch, "main checkout"), linked = join(scratch, "linked checkout");
const previousRole = process.env.NOGG_SESSION_ROLE;
try {
  execFileSync("git", ["init", "-q", main]);
  mkdirSync(join(main, ".nogging"));
  const config = join(main, ".nogging/config.json");
  writeFileSync(config, "{}");
  execFileSync("git", ["-C", main, "add", "."]);
  execFileSync("git", ["-C", main, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "seed"]);
  execFileSync("git", ["-C", main, "worktree", "add", "-q", "--detach", linked]);
  const locks = join(main, ".nogging/locks");
  mkdirSync(locks);
  const lockPath = join(locks, "planning.lock"), sentinel = join(locks, "openspec.readonly");
  const fresh = () => ({ pid: process.pid, host: "fixture", created_at: new Date().toISOString() });
  const put = (record) => writeFileSync(lockPath, JSON.stringify(record));
  assert.equal(openspecBoundaryOpen(scratch, "planning"), false);
  assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  put(fresh());
  assert.equal(openspecBoundaryOpen(linked, "planning"), true);
  assert.equal(openspecBoundaryOpen(main, "planning"), true);
  delete process.env.NOGG_SESSION_ROLE;
  assert.equal(openspecBoundaryOpen(linked), false);
  for (const role of ["lead", "specialist:backend-engineer", "orchestrator", "planner", ""]) {
    assert.equal(openspecBoundaryOpen(linked, role), false, role);
  }
  for (const record of [null, [], {}, { ...fresh(), pid: true }, { ...fresh(), pid: -1 },
                        { ...fresh(), host: "" }, { ...fresh(), created_at: "bad" },
                        { ...fresh(), created_at: "2000-01-01T00:00:00Z" },
                        { ...fresh(), created_at: new Date(Date.now() + 3600000).toISOString() }]) {
    put(record);
    assert.equal(openspecBoundaryOpen(linked, "planning"), false, JSON.stringify(record));
  }
  writeFileSync(lockPath, "{broken JSON");
  assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  put(fresh());
  chmodSync(lockPath, 0);
  if (!process.getuid || process.getuid() !== 0) assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  chmodSync(lockPath, 0o600);
  writeFileSync(sentinel, "closed");
  assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  rmSync(sentinel);
  symlinkSync(join(scratch, "missing-sentinel-target"), sentinel);
  assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  rmSync(sentinel);
  mkdirSync(join(linked, ".nogging/locks"));
  const localSentinel = join(linked, ".nogging/locks/openspec.readonly");
  writeFileSync(localSentinel, "legacy closed");
  assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  rmSync(localSentinel);
  rmSync(lockPath);
  writeFileSync(join(linked, ".nogging/locks/planning.lock"), JSON.stringify(fresh()));
  assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  put(fresh());
  writeFileSync(config, "{broken config");
  assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  writeFileSync(config, JSON.stringify({ planning_lock_ttl_seconds: "7200" }));
  assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  writeFileSync(config, JSON.stringify({ planning_lock_ttl_seconds: null }));
  assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  writeFileSync(config, JSON.stringify({ planning_lock_ttl_seconds: 1 }));
  put({ ...fresh(), created_at: new Date(Date.now() - 2000).toISOString() });
  assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  writeFileSync(config, JSON.stringify({ planning_lock_ttl_seconds: 10 }));
  assert.equal(openspecBoundaryOpen(linked, "planning"), true);
  put(fresh());
  const nested = join(linked, "src/nested");
  mkdirSync(nested, { recursive: true });
  mkdirSync(join(linked, "openspec"));
  symlinkSync(join(linked, "openspec"), join(linked, "spec-link"));
  for (const path of ["../../openspec/a.md", join(linked, "openspec/a.md"), "../../spec-link/a.md", join(main, "openspec/a.md")]) {
    assert.equal(mod.isUnderOpenspec(path, nested), true, path);
  }
  const third = join(scratch, "third checkout");
  execFileSync("git", ["-C", main, "worktree", "add", "-q", "--detach", third]);
  assert.equal(mod.isUnderOpenspec(join(third, "openspec/new.md"), nested), true);
  assert.equal(mod.isUnderOpenspec(join(third, "openspec/new.md"), main), true);
  assert.equal(mod.isUnderOpenspec("../file.ts", nested), false);
  assert.equal(mod.isUnderOpenspec("../../openspec-other/a.md", nested), false);
  writeFileSync(config, "{}");
  chmodSync(config, 0);
  if (!process.getuid || process.getuid() !== 0) assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  chmodSync(config, 0o600);
  renameSync(join(main, ".git"), join(main, ".git-unavailable"));
  assert.equal(openspecBoundaryOpen(linked, "planning"), false);
  renameSync(join(main, ".git-unavailable"), join(main, ".git"));
  let handler;
  mod.default({ on(event, callback) { assert.equal(event, "tool_call"); handler = callback; } });
  const ctx = { cwd: linked, hasUI: false };
  process.env.NOGG_SESSION_ROLE = "lead";
  assert.equal((await handler({ toolName: "write", input: { path: "openspec/project.md" } }, ctx)).block, true);
  assert.equal(await handler({ toolName: "edit", input: { path: "src/file.ts" } }, ctx), undefined);
  process.env.NOGG_SESSION_ROLE = "planning";
  assert.equal(await handler({ toolName: "write", input: { path: "openspec/project.md" } }, ctx), undefined);
  const sessions = join(main, ".nogging/state/sessions");
  mkdirSync(sessions, { recursive: true });
  const sessionName = "owned-planner", sessionPath = join(sessions, sessionName + ".json");
  const stat = readFileSync(`/proc/${process.pid}/stat`, "utf8");
  const birth = stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/)[19];
  const owned = { ...fresh(), host: hostname(), session_name: sessionName,
    session_root: main, pid_start: birth, working_dir: linked };
  const session = { name: sessionName, role: "planning", host: hostname(), state: "running",
    working_dir: linked, session_pid: process.pid, session_pid_start: birth };
  const previousName = process.env.NOGG_SESSION_NAME, previousRoot = process.env.NOGG_SESSION_ROOT;
  try {
    process.env.NOGG_SESSION_NAME = sessionName;
    process.env.NOGG_SESSION_ROOT = main;
    writeFileSync(sessionPath, JSON.stringify(session));
    put(owned);
    assert.equal(openspecBoundaryOpen(linked), true);
    assert.equal(openspecBoundaryOpen(main), false);
    assert.equal(await handler({ toolName: "write", input: { path: "openspec/own.md" } }, ctx), undefined);
    assert.equal((await handler({ toolName: "write", input: { path: join(third, "openspec/foreign.md") } }, ctx)).block, true);
    process.env.NOGG_SESSION_NAME = "other-planner";
    assert.equal(openspecBoundaryOpen(linked), false);
    process.env.NOGG_SESSION_NAME = sessionName;
    for (const invalid of [{ ...session, state: "failed" }, { ...session, session_pid_start: "reused" },
                           { ...session, role: "lead" }, { ...session, host: "foreign-host" }]) {
      writeFileSync(sessionPath, JSON.stringify(invalid));
      assert.equal(openspecBoundaryOpen(linked), false);
    }
  } finally {
    if (previousName === undefined) delete process.env.NOGG_SESSION_NAME;
    else process.env.NOGG_SESSION_NAME = previousName;
    if (previousRoot === undefined) delete process.env.NOGG_SESSION_ROOT;
    else process.env.NOGG_SESSION_ROOT = previousRoot;
    put(fresh());
  }
  assert.equal((await handler({ toolName: "bash", input: { command: "sudo true" } }, ctx)).block, true);
  assert.equal(await handler({ toolName: "bash", input: { command: "sed -n '1,5p' openspec/project.md" } }, ctx), undefined);
  console.log("Pi canonical planning authority: missing/stale/malformed/unreadable state, sentinels, roles and tool calls passed");
} finally {
  if (previousRole === undefined) delete process.env.NOGG_SESSION_ROLE;
  else process.env.NOGG_SESSION_ROLE = previousRole;
  rmSync(scratch, { recursive: true, force: true });
}
NODE
