import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { usageCacheDir, usageCachePath, readUsageCache, writeUsageCache } from "./usage-cache.ts";

function scratch(): string {
  return mkdtempSync(path.join(tmpdir(), "usage-cache-"));
}

test("cache dir prefers XDG_CACHE_HOME", () => {
  const dir = usageCacheDir({ XDG_CACHE_HOME: "/x/cache", HOME: "/h" });
  assert.equal(dir, path.join("/x/cache", "nogging", "usage"));
});

test("cache dir falls back to HOME/.cache", () => {
  assert.equal(usageCacheDir({ HOME: "/h" }), path.join("/h", ".cache", "nogging", "usage"));
  assert.equal(usageCacheDir({ XDG_CACHE_HOME: "", HOME: "/h" }), path.join("/h", ".cache", "nogging", "usage"));
});

test("cache path appends the file name", () => {
  assert.equal(usageCachePath("pi-zai.json", { XDG_CACHE_HOME: "/x" }), path.join("/x", "nogging", "usage", "pi-zai.json"));
});

test("write creates a 0700 directory and a 0600 file", () => {
  const root = scratch();
  try {
    const env = { XDG_CACHE_HOME: path.join(root, "cache") };
    const file = writeUsageCache("pi-zai.json", { schema_version: 1 }, env);
    assert.equal(file, usageCachePath("pi-zai.json", env));
    assert.equal(statSync(path.dirname(file)).mode & 0o777, 0o700);
    assert.equal(statSync(file).mode & 0o777, 0o600);
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")), { schema_version: 1 });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("write replaces atomically and leaves no temp file", () => {
  const root = scratch();
  try {
    const env = { XDG_CACHE_HOME: root };
    writeUsageCache("pi-zai.json", { n: 1 }, env);
    writeUsageCache("pi-zai.json", { n: 2 }, env);
    const dir = usageCacheDir(env);
    assert.deepEqual(readdirSync(dir), ["pi-zai.json"]);
    assert.deepEqual(readUsageCache("pi-zai.json", env), { n: 2 });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("write tightens a pre-existing wide file to 0600", () => {
  const root = scratch();
  try {
    const env = { XDG_CACHE_HOME: root };
    const dir = usageCacheDir(env);
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, "pi-zai.json"), "{}", { mode: 0o666 });
    writeUsageCache("pi-zai.json", { n: 3 }, env);
    assert.equal(statSync(path.join(dir, "pi-zai.json")).mode & 0o777, 0o600);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("read returns undefined for a missing file", () => {
  const root = scratch();
  try {
    assert.equal(readUsageCache("nope.json", { XDG_CACHE_HOME: root }), undefined);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("read returns undefined for malformed or empty data", () => {
  const root = scratch();
  try {
    const env = { XDG_CACHE_HOME: root };
    const dir = usageCacheDir(env);
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, "bad.json"), "{not json");
    writeFileSync(path.join(dir, "empty.json"), "");
    assert.equal(readUsageCache("bad.json", env), undefined);
    assert.equal(readUsageCache("empty.json", env), undefined);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("read returns undefined when the path is a directory", () => {
  const root = scratch();
  try {
    const env = { XDG_CACHE_HOME: root };
    mkdirSync(path.join(usageCacheDir(env), "dir.json"), { recursive: true });
    assert.equal(readUsageCache("dir.json", env), undefined);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("a file name that escapes the cache directory is refused", () => {
  const env = { XDG_CACHE_HOME: "/x" };
  assert.throws(() => usageCachePath("../evil.json", env));
  assert.throws(() => usageCachePath("a/b.json", env));
  assert.throws(() => usageCachePath("", env));
});

test("defaults read process.env at call time", () => {
  const root = scratch();
  const saved = process.env.XDG_CACHE_HOME;
  try {
    process.env.XDG_CACHE_HOME = root;
    writeUsageCache("pi-zai.json", { ok: true });
    assert.deepEqual(readUsageCache("pi-zai.json"), { ok: true });
  } finally {
    if (saved === undefined) delete process.env.XDG_CACHE_HOME;
    else process.env.XDG_CACHE_HOME = saved;
    rmSync(root, { recursive: true, force: true });
  }
});
