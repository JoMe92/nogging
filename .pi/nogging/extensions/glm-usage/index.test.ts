import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readdirSync, readFileSync, rmSync, statSync, mkdirSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import factory, { create } from "./index.ts";
import { writeUsageCache, usageCachePath } from "../../lib/usage-cache.ts";

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const T = 1_790_000_000_000;
const KEY = "zai-secret-KEY-0123456789";
const URL = "https://api.z.ai/api/monitor/usage/quota/limit";
const REGISTRY = Symbol.for("nogging.glm-usage.active");

function body(now: number, opts: { short?: number; weekly?: number } = {}) {
  const limits: unknown[] = [
    { type: "TIME_LIMIT", unit: 5, percentage: 1, nextResetTime: now + DAY },
  ];
  limits.push({ type: "TOKENS_LIMIT", unit: 3, percentage: opts.short ?? 37, nextResetTime: now + 2 * HOUR + 14 * MIN });
  if (opts.weekly !== -1) {
    limits.push({ type: "TOKENS_LIMIT", unit: 6, percentage: opts.weekly ?? 21, nextResetTime: now + 3 * DAY + 6 * HOUR });
  }
  return { code: 200, success: true, data: { level: "pro", limits } };
}

type Handle = { ms: number; fn: () => void; unrefd: boolean; cleared: boolean; unref: () => Handle };

function harness(o: { hasUI?: boolean; key?: string | undefined | (() => Promise<string | undefined>); fetchImpl?: (url: string, init: any) => Promise<any>; timeoutMs?: number } = {}) {
  const root = mkdtempSync(path.join(tmpdir(), "glm-usage-"));
  const env = { XDG_CACHE_HOME: root, HOME: root };
  const clock = { t: T };
  const requests: { url: string; init: any }[] = [];
  const handles: Handle[] = [];
  const statuses: { key: string; text: string }[] = [];
  const notes: string[] = [];
  const commands = new Map<string, any>();
  const handlers = new Map<string, (event: any, ctx: any) => any>();
  const keyCalls: string[] = [];
  const fetchImpl = o.fetchImpl ?? (async () => ({ ok: true, status: 200, json: async () => body(clock.t) }));
  const deps = {
    fetch: async (url: string, init: any) => {
      requests.push({ url, init });
      return fetchImpl(url, init);
    },
    now: () => clock.t,
    env,
    setInterval: (fn: () => void, ms: number) => {
      const h: Handle = { ms, fn, unrefd: false, cleared: false, unref() { h.unrefd = true; return h; } };
      handles.push(h);
      return h;
    },
    clearInterval: (h: Handle) => { h.cleared = true; },
    timeoutMs: o.timeoutMs,
  };
  const pi = {
    registerCommand: (name: string, spec: any) => { commands.set(name, spec); },
    on: (name: string, fn: any) => { handlers.set(name, fn); },
  };
  const ctx = {
    hasUI: o.hasUI ?? true,
    ui: {
      setStatus: (key: string, text: string) => { statuses.push({ key, text }); },
      notify: (text: string) => { notes.push(text); },
    },
    modelRegistry: {
      getApiKeyForProvider: async (p: string) => {
        keyCalls.push(p);
        if (typeof o.key === "function") return o.key();
        return "key" in o ? o.key : KEY;
      },
    },
  };
  const h = {
    root, env, clock, requests, handles, statuses, notes, commands, handlers, keyCalls, ctx,
    footer: () => statuses[statuses.length - 1]?.text,
    start: async () => { create(deps)(pi); await h.handlers.get("session_start")?.({}, ctx); await idle(); },
    load: (extra = {}) => { create({ ...deps, ...extra })(pi); },
    pi,
    shutdown: async () => { await h.handlers.get("session_shutdown")?.({}, ctx); },
    command: async (args = "") => { await h.commands.get("glm-usage").handler(args, ctx); await idle(); },
    snapshotPath: usageCachePath("pi-zai.json", env),
    cleanup: async () => { await h.shutdown(); delete (globalThis as any)[REGISTRY]; rmSync(root, { recursive: true, force: true }); },
  };
  return h;
}

async function idle() {
  for (let i = 0; i < 5; i++) await new Promise((r) => setImmediate(r));
}

function everything(h: ReturnType<typeof harness>): string {
  let files = "";
  const dir = path.dirname(h.snapshotPath);
  try { for (const f of readdirSync(dir)) files += readFileSync(path.join(dir, f), "utf8"); } catch {}
  return JSON.stringify(h.statuses) + JSON.stringify(h.notes) + files;
}

test("default export is a factory; loading it starts no timer and no request", async () => {
  assert.equal(typeof factory, "function");
  const h = harness();
  try {
    h.load();
    assert.equal(h.requests.length, 0);
    assert.equal(h.handles.length, 0);
    assert.equal(h.statuses.length, 0);
    assert.ok(h.commands.has("glm-usage"));
    assert.ok(h.handlers.has("session_start"));
    assert.ok(h.handlers.has("session_shutdown"));
  } finally { await h.cleanup(); }
});

test("session_start fetches with the Pi-resolved key and shows the exact footer", async () => {
  const h = harness();
  try {
    await h.start();
    assert.deepEqual(h.keyCalls, ["zai"]);
    assert.equal(h.requests.length, 1);
    assert.equal(h.requests[0].url, URL);
    assert.equal(h.requests[0].init.headers.Authorization, `Bearer ${KEY}`);
    assert.ok(h.requests[0].init.signal);
    assert.equal(h.statuses[0].key, "nogging-glm-usage");
    assert.equal(h.footer(), "GLM 5h 63% free · reset 2h 14m | week 79% free · reset 3d 6h");
  } finally { await h.cleanup(); }
});

test("polls every 180 s from one unref'd timer, cleared by an idempotent shutdown", async () => {
  const h = harness();
  try {
    await h.start();
    assert.equal(h.handles.length, 1);
    assert.equal(h.handles[0].ms, 180_000);
    assert.equal(h.handles[0].unrefd, true);
    h.clock.t += 180_000;
    h.handles[0].fn();
    await idle();
    assert.equal(h.requests.length, 2);
    await h.shutdown();
    await h.shutdown();
    assert.equal(h.handles[0].cleared, true);
    assert.equal(h.handles.length, 1);
  } finally { await h.cleanup(); }
});

test("print mode starts no timer and makes no request", async () => {
  const h = harness({ hasUI: false });
  try {
    await h.start();
    assert.equal(h.requests.length, 0);
    assert.equal(h.handles.length, 0);
    assert.equal(h.keyCalls.length, 0);
  } finally { await h.cleanup(); }
});

test("no key: no request, footer says so, the next tick fetches once a key appears", async () => {
  let key: string | undefined;
  const h = harness({ key: async () => key });
  try {
    await h.start();
    assert.equal(h.requests.length, 0);
    assert.equal(h.footer(), "GLM usage: no Z.ai key");
    key = KEY;
    h.clock.t += 180_000;
    h.handles[0].fn();
    await idle();
    assert.equal(h.requests.length, 1);
    assert.match(h.footer()!, /^GLM 5h 63% free/);
  } finally { await h.cleanup(); }
});

test("a throwing key lookup is treated as no key", async () => {
  const h = harness({ key: async () => { throw new Error(`boom ${KEY}`); } });
  try {
    await h.start();
    assert.equal(h.requests.length, 0);
    assert.equal(h.footer(), "GLM usage: no Z.ai key");
    assert.equal(everything(h).includes(KEY), false);
  } finally { await h.cleanup(); }
});

test("a fresh shared snapshot is used without a request", async () => {
  const h = harness();
  try {
    writeUsageCache("pi-zai.json", {
      schema_version: 1, provider: "zai", source: "pi-extension",
      observed_at: new Date(T - 40_000).toISOString().replace(/\.\d{3}Z$/, "Z"),
      plan_level: "pro",
      windows: {
        short: { used_percent: 10, resets_at: new Date(T + HOUR).toISOString() },
        weekly: { used_percent: 20, resets_at: new Date(T + DAY).toISOString() },
      },
    }, h.env);
    await h.start();
    assert.equal(h.requests.length, 0);
    assert.equal(h.footer(), "GLM 5h 90% free · reset 1h 0m | week 80% free · reset 1d 0h");
  } finally { await h.cleanup(); }
});

test("an old shared snapshot is not used: the tick fetches", async () => {
  const h = harness();
  try {
    writeUsageCache("pi-zai.json", {
      schema_version: 1, provider: "zai", source: "pi-extension",
      observed_at: new Date(T - 121_000).toISOString(),
      windows: { short: { used_percent: 10, resets_at: new Date(T + HOUR).toISOString() } },
    }, h.env);
    await h.start();
    assert.equal(h.requests.length, 1);
  } finally { await h.cleanup(); }
});

test("a successful fetch writes a 0600 key-free snapshot in a 0700 directory", async () => {
  const h = harness();
  try {
    await h.start();
    const file = h.snapshotPath;
    assert.equal(statSync(file).mode & 0o777, 0o600);
    assert.equal(statSync(path.dirname(file)).mode & 0o777, 0o700);
    const text = readFileSync(file, "utf8");
    assert.equal(text.includes(KEY), false);
    const snap = JSON.parse(text);
    assert.equal(snap.schema_version, 1);
    assert.equal(snap.provider, "zai");
    assert.equal(snap.source, "pi-extension");
    assert.equal(snap.plan_level, "pro");
    assert.equal(snap.windows.short.used_percent, 37);
    assert.equal(snap.windows.weekly.used_percent, 21);
    assert.equal(snap.observed_at, new Date(T).toISOString().replace(/\.\d{3}Z$/, "Z"));
    assert.deepEqual(Object.keys(snap).sort(), ["observed_at", "plan_level", "provider", "schema_version", "source", "windows"]);
  } finally { await h.cleanup(); }
});

test("a weekly window the plan lacks is left out of footer and snapshot", async () => {
  const h = harness({ fetchImpl: async () => ({ ok: true, status: 200, json: async () => body(T, { weekly: -1 }) }) });
  try {
    await h.start();
    assert.equal(h.footer(), "GLM 5h 63% free · reset 2h 14m");
    assert.deepEqual(Object.keys(JSON.parse(readFileSync(h.snapshotPath, "utf8")).windows), ["short"]);
  } finally { await h.cleanup(); }
});

test("a snapshot write failure does not stop the footer and /glm-usage reports it", async () => {
  const h = harness();
  try {
    // A file where the cache directory should be makes the write fail.
    const blocker = path.join(h.root, "nogging");
    mkdirSync(h.root, { recursive: true });
    (await import("node:fs")).writeFileSync(blocker, "x");
    await h.start();
    assert.match(h.footer()!, /^GLM 5h 63% free/);
    h.clock.t += 31_000;
    await h.command();
    assert.match(h.notes[0], /snapshot write error: \S+/);
  } finally { await h.cleanup(); }
});

for (const [name, impl, reason] of [
  ["http error", async () => ({ ok: false, status: 401, json: async () => ({}) }), "http-401"],
  ["api code", async () => ({ ok: true, status: 200, json: async () => ({ code: 500 }) }), "api-code-500"],
  ["network", async () => { throw new Error(`connect ECONNREFUSED ${KEY}`); }, "network"],
  ["malformed json", async () => ({ ok: true, status: 200, json: async () => { throw new SyntaxError(`bad ${KEY}`); } }), "malformed"],
  ["malformed shape", async () => ({ ok: true, status: 200, json: async () => ({ code: 200, data: {} }) }), "malformed"],
] as const) {
  test(`no good value yet + ${name}: unavailable (${reason}), key never surfaces`, async () => {
    const h = harness({ fetchImpl: impl as any });
    try {
      await h.start();
      assert.equal(h.footer(), `GLM usage unavailable (${reason})`);
      assert.equal(everything(h).includes(KEY), false);
      h.clock.t += 31_000;
      await h.command();
      assert.match(h.notes[0], new RegExp(reason));
      assert.equal(everything(h).includes(KEY), false);
    } finally { await h.cleanup(); }
  });
}

test("timeout: the request is aborted and reported as timeout", async () => {
  const h = harness({
    timeoutMs: 20,
    fetchImpl: (_u, init) => new Promise((_res, rej) => {
      init.signal.addEventListener("abort", () => rej(Object.assign(new Error(`aborted ${KEY}`), { name: "AbortError" })));
    }),
  });
  try {
    await h.start();
    await new Promise((r) => setTimeout(r, 60));
    await idle();
    assert.equal(h.footer(), "GLM usage unavailable (timeout)");
    assert.equal(everything(h).includes(KEY), false);
  } finally { await h.cleanup(); }
});

test("error after a good value keeps the values and marks them stale; a reset passes", async () => {
  let fail = false;
  const h = harness({
    fetchImpl: async () => fail
      ? { ok: false, status: 503, json: async () => ({}) }
      : { ok: true, status: 200, json: async () => body(h.clock.t) },
  });
  try {
    await h.start();
    fail = true;
    h.clock.t += 7 * MIN;
    h.handles[0].fn();
    await idle();
    assert.equal(h.footer(), "GLM 5h 63% free · reset 2h 7m | week 79% free · reset 3d 5h · stale 7m");
    h.clock.t += 3 * HOUR;
    h.handles[0].fn();
    await idle();
    assert.match(h.footer()!, /^GLM 5h reset passed \| week 79% free · reset 3d 2h · stale 3h 7m$/);
    // Recovery clears the stale marker.
    fail = false;
    h.clock.t += 180_000;
    h.handles[0].fn();
    await idle();
    assert.doesNotMatch(h.footer()!, /stale/);
  } finally { await h.cleanup(); }
});

test("/glm-usage forces a refresh at most once per 30 s", async () => {
  const h = harness();
  try {
    await h.start();
    assert.equal(h.requests.length, 1);
    h.clock.t += 10_000;
    await h.command();
    assert.equal(h.requests.length, 1, "inside 30 s of the last request: no new request");
    assert.equal(h.notes.length, 1);
    h.clock.t += 21_000;
    await h.command();
    assert.equal(h.requests.length, 2);
    h.clock.t += 5_000;
    await h.command();
    assert.equal(h.requests.length, 2);
    assert.equal(h.notes.length, 3);
  } finally { await h.cleanup(); }
});

test("/glm-usage bypasses a fresh snapshot and reports the full state", async () => {
  const h = harness({ hasUI: false });
  try {
    h.load();
    await h.command();
    assert.equal(h.requests.length, 1, "print mode command still fetches");
    assert.equal(h.handles.length, 0);
    const report = h.notes[0];
    assert.match(report, /plan: pro/);
    assert.match(report, /5h window: 37% used · 63% free/);
    assert.match(report, /week window: 21% used · 79% free/);
    assert.match(report, /last good observation:/);
    assert.ok(report.includes(h.snapshotPath));
    assert.equal(report.includes(KEY), false);
  } finally { await h.cleanup(); }
});

test("/glm-usage after an http-401 names the reason, the last good values and their age", async () => {
  let fail = false;
  const h = harness({
    fetchImpl: async () => fail ? { ok: false, status: 401, json: async () => ({}) } : { ok: true, status: 200, json: async () => body(h.clock.t) },
  });
  try {
    await h.start();
    fail = true;
    h.clock.t += 7 * MIN;
    h.handles[0].fn();
    await idle();
    h.clock.t += 31_000;
    await h.command();
    const report = h.notes[h.notes.length - 1];
    assert.match(report, /http-401/);
    assert.match(report, /37% used/);
    assert.match(report, /\(7m ago\)|\(8m ago\)/);
  } finally { await h.cleanup(); }
});

test("/glm-usage with no key sends no request", async () => {
  const h = harness({ key: undefined });
  try {
    h.load();
    await h.command();
    assert.equal(h.requests.length, 0);
    assert.match(h.notes[0], /no Z\.ai key/);
  } finally { await h.cleanup(); }
});

test("a throwing handler never escapes", async () => {
  const h = harness();
  try {
    h.ctx.ui.setStatus = () => { throw new Error("ui gone"); };
    h.ctx.ui.notify = () => { throw new Error("ui gone"); };
    await h.start();
    await h.command();
    await h.shutdown();
  } finally { await h.cleanup(); }
});

test("loading twice yields one instance; shutdown releases for a reload", async () => {
  const h = harness();
  try {
    const first = new Map<string, any>();
    const second = new Map<string, any>();
    const mk = (cmds: Map<string, any>) => ({ registerCommand: (n: string, s: any) => cmds.set(n, s), on: (n: string, f: any) => cmds.set(`on:${n}`, f) });
    const deps = { fetch: async () => ({ ok: true, status: 200, json: async () => body(T) }), now: () => T, env: h.env, setInterval: h.handles.push.bind(h.handles) as any, clearInterval: () => {} };
    create(deps as any)(mk(first));
    create(deps as any)(mk(second));
    assert.ok(first.has("glm-usage"));
    assert.equal(second.size, 0, "second activation registers nothing");
    await first.get("on:session_shutdown")({}, h.ctx);
    const third = new Map<string, any>();
    create(deps as any)(mk(third));
    assert.ok(third.has("glm-usage"), "a reload registers again");
    await third.get("on:session_shutdown")({}, h.ctx);
  } finally { await h.cleanup(); }
});

test("a key never leaves the request header", async () => {
  const h = harness();
  try {
    await h.start();
    await h.command();
    h.clock.t += 31_000;
    await h.command();
    assert.equal(everything(h).includes(KEY), false);
    const { headers, ...rest } = h.requests[0].init;
    assert.equal(JSON.stringify(rest).includes(KEY), false);
    assert.equal(Object.values(headers).filter((v) => String(v).includes(KEY)).length, 1);
    assert.equal(h.requests[0].url.includes(KEY), false);
  } finally { await h.cleanup(); }
});
