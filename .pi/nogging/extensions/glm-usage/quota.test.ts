import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  parseQuota,
  formatRelative,
  formatFooter,
  formatReport,
  buildSnapshot,
  parseSnapshot,
} from "./quota.ts";

const here = path.dirname(fileURLToPath(import.meta.url));
function fixture(name: string): unknown {
  return JSON.parse(readFileSync(path.join(here, "test", "fixtures", name), "utf8"));
}

const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;
const T = 1_790_000_000_000;

test("parses both windows from the fixture", () => {
  const r = parseQuota(fixture("both-windows.json"));
  assert.deepEqual(r, {
    ok: true,
    quota: {
      level: "placeholder-level",
      short: { usedPercent: 37, resetsAtMs: 1792000000000 },
      weekly: { usedPercent: 21, resetsAtMs: 1792200000000 },
    },
  });
});

test("ignores TIME_LIMIT entries", () => {
  const r = parseQuota(fixture("time-limit-unit5.json"));
  assert.equal(r.ok, true);
  if (r.ok) {
    assert.equal(r.quota.short?.usedPercent, 37);
    assert.equal(r.quota.weekly?.usedPercent, 21);
  }
});

test("a window the plan lacks is unavailable", () => {
  const r = parseQuota(fixture("weekly-absent.json"));
  assert.equal(r.ok, true);
  if (r.ok) {
    assert.equal(r.quota.short?.usedPercent, 37);
    assert.equal(r.quota.weekly, undefined);
  }
});

test("fixed reasons for unsupported shapes", () => {
  assert.deepEqual(parseQuota(fixture("code-500.json")), { ok: false, reason: "api-code-500" });
  assert.deepEqual(parseQuota(fixture("missing-limits.json")), { ok: false, reason: "malformed" });
  assert.deepEqual(parseQuota(fixture("non-finite.json")), { ok: false, reason: "malformed" });
  assert.deepEqual(parseQuota(fixture("out-of-range.json")), { ok: false, reason: "malformed" });
  for (const bad of [null, "x", 7, [], {}, { code: "200", data: { limits: [] } }, { code: 200, data: { limits: [] } }]) {
    assert.deepEqual(parseQuota(bad), { ok: false, reason: "malformed" });
  }
});

test("an invalid window does not stop the valid one; level must be a short string", () => {
  const body = {
    code: 200,
    data: {
      level: "x".repeat(200),
      limits: [
        { type: "TOKENS_LIMIT", unit: 3, percentage: 150, nextResetTime: T },
        { type: "TOKENS_LIMIT", unit: 6, percentage: 21, nextResetTime: T },
      ],
    },
  };
  const r = parseQuota(body);
  assert.equal(r.ok, true);
  if (r.ok) {
    assert.equal(r.quota.short, undefined);
    assert.equal(r.quota.weekly?.usedPercent, 21);
    assert.equal(r.quota.level, undefined);
  }
});

test("a plan level with control characters is dropped", () => {
  const body = (level: string) => ({ code: 200, data: { level, limits: [{ type: "TOKENS_LIMIT", unit: 3, percentage: 1, nextResetTime: T }] } });
  const r = parseQuota(body("\u001b[31mpro"));
  assert.equal(r.ok && r.quota.level, undefined);
  const ok = parseQuota(body("pro-plus 2"));
  assert.equal(ok.ok && ok.quota.level, "pro-plus 2");
});

test("relative time formatting", () => {
  assert.equal(formatRelative(2 * HOUR + 14 * MIN), "2h 14m");
  assert.equal(formatRelative(3 * DAY + 6 * HOUR + 59 * MIN), "3d 6h");
  assert.equal(formatRelative(45 * MIN), "45m");
  assert.equal(formatRelative(7 * MIN), "7m");
  assert.equal(formatRelative(10_000), "<1m");
  assert.equal(formatRelative(-5), "<1m");
});

const good = {
  level: "pro",
  short: { usedPercent: 37, resetsAtMs: T + 2 * HOUR + 14 * MIN },
  weekly: { usedPercent: 21, resetsAtMs: T + 3 * DAY + 6 * HOUR },
};

test("footer: exact normal string", () => {
  assert.equal(
    formatFooter({ quota: good, observedAtMs: T }, T),
    "GLM 5h 63% free · reset 2h 14m | week 79% free · reset 3d 6h",
  );
});

test("footer: relative time follows the clock", () => {
  assert.equal(
    formatFooter({ quota: good, observedAtMs: T }, T + HOUR),
    "GLM 5h 63% free · reset 1h 14m | week 79% free · reset 3d 5h",
  );
});

test("footer: only the reported window", () => {
  assert.equal(
    formatFooter({ quota: { short: good.short }, observedAtMs: T }, T),
    "GLM 5h 63% free · reset 2h 14m",
  );
});

test("footer: stale age after an error", () => {
  assert.equal(
    formatFooter({ quota: good, observedAtMs: T, error: "timeout" }, T + 7 * MIN),
    "GLM 5h 63% free · reset 2h 7m | week 79% free · reset 3d 5h · stale 7m",
  );
});

test("footer: reset passed replaces only the passed window", () => {
  const text = formatFooter({ quota: good, observedAtMs: T, error: "network" }, T + 3 * HOUR);
  assert.equal(text, "GLM 5h reset passed | week 79% free · reset 3d 3h · stale 3h 0m");
});

test("footer: unavailable with a reason, and no key", () => {
  assert.equal(formatFooter({ error: "http-401" }, T), "GLM usage unavailable (http-401)");
  assert.equal(formatFooter({ error: "malformed" }, T), "GLM usage unavailable (malformed)");
  assert.equal(formatFooter({ noKey: true }, T), "GLM usage: no Z.ai key");
  assert.equal(formatFooter({ noKey: true, quota: good, observedAtMs: T }, T), "GLM usage: no Z.ai key");
});

test("snapshot round trip and shape", () => {
  const snap = buildSnapshot(good, T);
  assert.deepEqual(Object.keys(snap), ["schema_version", "provider", "source", "observed_at", "plan_level", "windows"]);
  assert.equal(snap.schema_version, 1);
  assert.equal(snap.provider, "zai");
  assert.equal(snap.source, "pi-extension");
  assert.match(snap.observed_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  const back = parseSnapshot(JSON.parse(JSON.stringify(snap)));
  assert.ok(back);
  assert.equal(back.observedAtMs, Math.floor(T / 1000) * 1000);
  assert.equal(back.quota.level, "pro");
  assert.equal(back.quota.short?.usedPercent, 37);
  assert.equal(Math.floor(back.quota.weekly!.resetsAtMs / 1000), Math.floor(good.weekly.resetsAtMs / 1000));
});

test("snapshot omits absent windows and plan level", () => {
  const snap = buildSnapshot({ weekly: good.weekly }, T);
  assert.deepEqual(Object.keys(snap.windows), ["weekly"]);
  assert.equal("plan_level" in snap, false);
});

test("parseSnapshot rejects foreign or malformed content", () => {
  const ok = JSON.parse(JSON.stringify(buildSnapshot(good, T)));
  assert.ok(parseSnapshot(ok));
  assert.ok(parseSnapshot({ ...ok, source: "nogg-probe" }));
  assert.equal(parseSnapshot(undefined), undefined);
  assert.equal(parseSnapshot({ ...ok, schema_version: 2 }), undefined);
  assert.equal(parseSnapshot({ ...ok, provider: "other" }), undefined);
  assert.equal(parseSnapshot({ ...ok, observed_at: "nope" }), undefined);
  assert.equal(parseSnapshot({ ...ok, windows: {} }), undefined);
  assert.equal(parseSnapshot({ ...ok, windows: { short: { used_percent: 500, resets_at: ok.windows.short.resets_at } } }), undefined);
});

test("report lists plan, windows, observation, reason and snapshot path; never a key", () => {
  const text = formatReport(
    { quota: good, observedAtMs: T, error: "http-401" },
    T + 7 * MIN,
    { snapshotPath: "/c/nogging/usage/pi-zai.json", snapshotError: "EACCES" },
  );
  assert.match(text, /plan: pro/);
  assert.match(text, /5h window: 37% used · 63% free · resets \d{4}-\d\d-\d\dT[\d:]+Z \(in 2h 7m\)/);
  assert.match(text, /week window: 21% used · 79% free/);
  assert.match(text, /last good observation: \d{4}-\d\d-\d\dT[\d:]+Z \(7m ago\)/);
  assert.match(text, /http-401/);
  assert.match(text, /stale 7m/);
  assert.match(text, /snapshot: \/c\/nogging\/usage\/pi-zai\.json/);
  assert.match(text, /snapshot write error: EACCES/);
});

test("report with nothing good yet", () => {
  const text = formatReport({ error: "timeout" }, T, { snapshotPath: "/p" });
  assert.match(text, /no good observation yet/);
  assert.match(text, /timeout/);
  assert.equal(formatReport({ noKey: true }, T, { snapshotPath: "/p" }).includes("no Z.ai key"), true);
});
