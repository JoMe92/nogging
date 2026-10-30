/**
 * Nogging glm-usage: Z.ai coding-plan quota in the Pi footer and `/glm-usage`.
 *
 * The key comes only from `ctx.modelRegistry.getApiKeyForProvider("zai")`, on
 * each refresh, and goes only into the Authorization header of the constant
 * endpoint below. It is never kept, logged, shown or stored; every failure is
 * reduced to a fixed reason (see quota.ts). Polling runs only with a UI, one
 * refresh at session_start and then every 180 s from an unref'd timer, and a
 * shared snapshot younger than 120 s replaces the request so several Pi
 * sessions make about one request per interval between them.
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readUsageCache, usageCachePath, writeUsageCache } from "../../lib/usage-cache.ts";
import type { CacheEnv } from "../../lib/usage-cache.ts";
import { buildSnapshot, formatFooter, formatReport, parseQuota, parseSnapshot } from "./quota.ts";
import type { State } from "./quota.ts";

// Constant on purpose: no setting or environment variable may redirect the key.
const ENDPOINT = "https://api.z.ai/api/monitor/usage/quota/limit";
const STATUS_KEY = "nogging-glm-usage";
const SNAPSHOT_FILE = "pi-zai.json";
const POLL_MS = 180_000;
const SNAPSHOT_FRESH_MS = 120_000;
const COMMAND_MIN_MS = 30_000;
const REQUEST_TIMEOUT_MS = 10_000;
const CLOCK_SKEW_MS = 5_000;
const REGISTRY = Symbol.for("nogging.glm-usage.active");

export type Deps = {
  fetch?: (url: string, init: { headers: Record<string, string>; signal: AbortSignal }) => Promise<any>;
  now?: () => number;
  env?: CacheEnv;
  setInterval?: (fn: () => void, ms: number) => any;
  clearInterval?: (handle: any) => void;
  timeoutMs?: number;
};

type Ctx = ExtensionContext;

export function create(deps: Deps = {}) {
  const now = deps.now ?? (() => Date.now());
  const env = deps.env ?? process.env;
  const doFetch = deps.fetch ?? ((url, init) => (globalThis as any).fetch(url, init));
  const startTimer = deps.setInterval ?? ((fn, ms) => setInterval(fn, ms));
  const stopTimer = deps.clearInterval ?? ((h) => clearInterval(h));
  const timeoutMs = deps.timeoutMs ?? REQUEST_TIMEOUT_MS;

  return function factory(pi: ExtensionAPI): void {
    const registry = globalThis as any;
    if (registry[REGISTRY]) return;
    const token = {};
    registry[REGISTRY] = token;

    let state: State = {};
    let timer: any;
    let uiCtx: Ctx | undefined;
    let inflight: Promise<void> | undefined;
    let lastFetchMs = -Infinity;
    let snapshotError: string | undefined;

    function render(ctx: Ctx | undefined): void {
      if (!ctx?.hasUI) return;
      try {
        ctx.ui.setStatus(STATUS_KEY, formatFooter(state, now()));
      } catch {
        // A UI that went away must not break the session.
      }
    }

    async function fetchQuota(key: string): Promise<{ ok: true; body: unknown } | { ok: false; reason: string }> {
      const controller = new AbortController();
      let timedOut = false;
      const timeout = setTimeout(() => { timedOut = true; controller.abort(); }, timeoutMs);
      try {
        const res = await doFetch(ENDPOINT, {
          headers: { Authorization: `Bearer ${key}`, Accept: "application/json" },
          signal: controller.signal,
        });
        if (!res.ok) return { ok: false, reason: `http-${Number.isInteger(res.status) ? res.status : 0}` };
        try {
          return { ok: true, body: await res.json() };
        } catch {
          return { ok: false, reason: timedOut ? "timeout" : "malformed" };
        }
      } catch {
        return { ok: false, reason: timedOut ? "timeout" : "network" };
      } finally {
        clearTimeout(timeout);
      }
    }

    async function doRefresh(ctx: Ctx, force: boolean): Promise<void> {
      let key: string | undefined;
      try {
        key = await ctx.modelRegistry.getApiKeyForProvider("zai");
      } catch {
        key = undefined;
      }
      if (!key) {
        state = { noKey: true, quota: state.quota, observedAtMs: state.observedAtMs };
        return;
      }
      if (!force) {
        const shared = parseSnapshot(readUsageCache(SNAPSHOT_FILE, env));
        if (shared) {
          const age = now() - shared.observedAtMs;
          if (age >= -CLOCK_SKEW_MS && age < SNAPSHOT_FRESH_MS) {
            state = { quota: shared.quota, observedAtMs: shared.observedAtMs };
            return;
          }
        }
      }
      lastFetchMs = now();
      const res = await fetchQuota(key);
      const parsed = res.ok ? parseQuota(res.body) : res;
      if (!parsed.ok) {
        state = { quota: state.quota, observedAtMs: state.observedAtMs, error: parsed.reason };
        return;
      }
      const observedAtMs = now();
      state = { quota: parsed.quota, observedAtMs };
      try {
        writeUsageCache(SNAPSHOT_FILE, buildSnapshot(parsed.quota, observedAtMs), env);
        snapshotError = undefined;
      } catch (err) {
        const code = (err as { code?: unknown })?.code;
        snapshotError = typeof code === "string" && /^[A-Z0-9_]+$/.test(code) ? code : "write-failed";
      }
    }

    // One refresh at a time: a tick that lands during a slow request joins it.
    function refresh(ctx: Ctx, force: boolean): Promise<void> {
      if (!inflight) {
        inflight = doRefresh(ctx, force)
          .catch(() => { state = { quota: state.quota, observedAtMs: state.observedAtMs, error: "malformed" }; })
          .finally(() => { inflight = undefined; });
      }
      return inflight;
    }

    async function tick(ctx: Ctx): Promise<void> {
      try {
        await refresh(ctx, false);
        render(ctx);
      } catch {
        // Never escapes a timer.
      }
    }

    pi.on("session_start", async (_event: unknown, ctx: Ctx) => {
      try {
        if (!ctx.hasUI) return;
        uiCtx = ctx;
        if (!timer) {
          timer = startTimer(() => { void tick(ctx); }, POLL_MS);
          timer?.unref?.();
        }
        void tick(ctx);
      } catch {
        // A failure here must not stop the session from starting.
      }
    });

    pi.on("session_shutdown", async () => {
      try {
        if (timer !== undefined) stopTimer(timer);
        timer = undefined;
        uiCtx = undefined;
      } catch {
        // Idempotent and silent.
      } finally {
        if (registry[REGISTRY] === token) delete registry[REGISTRY];
      }
    });

    pi.registerCommand("glm-usage", {
      description: "Show Z.ai GLM coding-plan quota (refreshes at most every 30 s)",
      handler: async (_args: string, ctx: Ctx) => {
        try {
          // Any request counts, so a command right after a tick shows its result.
          if (now() - lastFetchMs >= COMMAND_MIN_MS) {
            await refresh(ctx, true);
            render(uiCtx ?? ctx);
          }
          const report = formatReport(state, now(), {
            snapshotPath: usageCachePath(SNAPSHOT_FILE, env),
            snapshotError,
          });
          ctx.ui.notify(report, "info");
        } catch {
          // Nothing escapes a command handler.
        }
      },
    });
  };
}

export default function (pi: ExtensionAPI): void {
  create()(pi);
}
