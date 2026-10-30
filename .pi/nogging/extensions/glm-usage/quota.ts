// Pure Z.ai quota parsing and formatting for the glm-usage extension.
//
// Nothing here touches the network, the clock, the disk or a credential: the
// caller injects the response body and the current time. Errors are reduced to
// the fixed reasons below, so no response text can reach a footer or report.

export type QuotaWindow = { usedPercent: number; resetsAtMs: number };
export type Quota = { level?: string; short?: QuotaWindow; weekly?: QuotaWindow };
export type ParseResult = { ok: true; quota: Quota } | { ok: false; reason: string };

// Footer and report input. `quota` and `observedAtMs` are the last good values;
// `error` is the fixed reason of the latest failed refresh, cleared on success.
export type State = { quota?: Quota; observedAtMs?: number; error?: string; noKey?: boolean };

const MAX_LEVEL_LENGTH = 32;
const MIN = 60_000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function percent(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) && v >= 0 && v <= 100 ? v : undefined;
}

function instant(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) && v > 0 ? v : undefined;
}

function level(v: unknown): string | undefined {
  // Server text reaches the terminal, so only plain label characters pass.
  return typeof v === "string" && v.length <= MAX_LEVEL_LENGTH && /^[A-Za-z0-9 ._-]+$/.test(v) ? v : undefined;
}

function windowOf(entry: Record<string, unknown>): QuotaWindow | undefined {
  const usedPercent = percent(entry.percentage);
  const resetsAtMs = instant(entry.nextResetTime);
  return usedPercent === undefined || resetsAtMs === undefined ? undefined : { usedPercent, resetsAtMs };
}

export function parseQuota(body: unknown): ParseResult {
  if (!isRecord(body) || typeof body.code !== "number" || !Number.isFinite(body.code)) {
    return { ok: false, reason: "malformed" };
  }
  if (body.code !== 200) return { ok: false, reason: `api-code-${body.code}` };
  const data = body.data;
  if (!isRecord(data) || !Array.isArray(data.limits)) return { ok: false, reason: "malformed" };
  const quota: Quota = {};
  for (const entry of data.limits) {
    if (!isRecord(entry) || entry.type !== "TOKENS_LIMIT") continue;
    const key = entry.unit === 3 ? "short" : entry.unit === 6 ? "weekly" : undefined;
    if (key === undefined || quota[key] !== undefined) continue;
    const win = windowOf(entry);
    if (win) quota[key] = win;
  }
  if (!quota.short && !quota.weekly) return { ok: false, reason: "malformed" };
  const plan = level(data.level);
  return { ok: true, quota: plan === undefined ? quota : { level: plan, ...quota } };
}

// "3d 6h" from a day up, "2h 14m" from an hour up, otherwise "45m".
export function formatRelative(ms: number): string {
  const minutes = Math.floor(Math.max(0, ms) / MIN);
  if (minutes < 1) return "<1m";
  const days = Math.floor(minutes / (DAY / MIN));
  const hours = Math.floor((minutes % (DAY / MIN)) / (HOUR / MIN));
  if (days > 0) return `${days}d ${hours}h`;
  if (hours > 0) return `${hours}h ${minutes % 60}m`;
  return `${minutes}m`;
}

function free(win: QuotaWindow): number {
  return Math.round(100 - win.usedPercent);
}

function segment(label: string, win: QuotaWindow, nowMs: number): string {
  if (win.resetsAtMs <= nowMs) return `${label} reset passed`;
  return `${label} ${free(win)}% free · reset ${formatRelative(win.resetsAtMs - nowMs)}`;
}

export function formatFooter(state: State, nowMs: number): string {
  if (state.noKey) return "GLM usage: no Z.ai key";
  const quota = state.quota;
  if (!quota) return `GLM usage unavailable (${state.error ?? "malformed"})`;
  const parts: string[] = [];
  if (quota.short) parts.push(segment("5h", quota.short, nowMs));
  if (quota.weekly) parts.push(segment("week", quota.weekly, nowMs));
  let text = `GLM ${parts.join(" | ")}`;
  if (state.error && state.observedAtMs !== undefined) {
    text += ` · stale ${formatRelative(nowMs - state.observedAtMs)}`;
  }
  return text;
}

function iso(ms: number): string {
  return new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
}

export type ReportExtras = { snapshotPath: string; snapshotError?: string };

export function formatReport(state: State, nowMs: number, extras: ReportExtras): string {
  const lines = ["GLM usage (Z.ai coding plan)"];
  const quota = state.quota;
  if (quota) {
    lines.push(`plan: ${quota.level ?? "unknown"}`);
    for (const [label, win] of [["5h", quota.short], ["week", quota.weekly]] as const) {
      if (!win) continue;
      const when = win.resetsAtMs <= nowMs
        ? "reset passed"
        : `resets ${iso(win.resetsAtMs)} (in ${formatRelative(win.resetsAtMs - nowMs)})`;
      lines.push(`${label} window: ${Math.round(win.usedPercent)}% used · ${free(win)}% free · ${when}`);
    }
  }
  if (state.observedAtMs !== undefined && quota) {
    lines.push(`last good observation: ${iso(state.observedAtMs)} (${formatRelative(nowMs - state.observedAtMs)} ago)`);
  } else {
    lines.push("no good observation yet");
  }
  if (state.noKey) lines.push("status: no Z.ai key (use /login); no request was sent");
  else if (state.error) {
    lines.push(`status: ${state.error}${quota && state.observedAtMs !== undefined ? ` · stale ${formatRelative(nowMs - state.observedAtMs)}` : ""}`);
  } else lines.push("status: ok");
  lines.push(`snapshot: ${extras.snapshotPath}`);
  if (extras.snapshotError) lines.push(`snapshot write error: ${extras.snapshotError}`);
  return lines.join("\n");
}

export type Snapshot = {
  schema_version: 1;
  provider: "zai";
  source: "pi-extension";
  observed_at: string;
  plan_level?: string;
  windows: { short?: { used_percent: number; resets_at: string }; weekly?: { used_percent: number; resets_at: string } };
};

// The key-free shared snapshot (design Decision 6). Absent windows are omitted.
export function buildSnapshot(quota: Quota, observedAtMs: number): Snapshot {
  const snap: Snapshot = {
    schema_version: 1,
    provider: "zai",
    source: "pi-extension",
    observed_at: iso(observedAtMs),
    ...(quota.level === undefined ? {} : { plan_level: quota.level }),
    windows: {},
  };
  for (const key of ["short", "weekly"] as const) {
    const win = quota[key];
    if (win) snap.windows[key] = { used_percent: win.usedPercent, resets_at: iso(win.resetsAtMs) };
  }
  return snap;
}

function snapshotWindow(v: unknown): QuotaWindow | undefined | null {
  if (v === undefined) return undefined;
  if (!isRecord(v)) return null;
  const usedPercent = percent(v.used_percent);
  const resetsAtMs = typeof v.resets_at === "string" ? Date.parse(v.resets_at) : NaN;
  return usedPercent === undefined || !Number.isFinite(resetsAtMs) ? null : { usedPercent, resetsAtMs };
}

// Reads a snapshot written by this extension or by `nogg usage` (source
// "nogg-probe"). Anything that does not fit the schema is undefined.
export function parseSnapshot(raw: unknown): { quota: Quota; observedAtMs: number } | undefined {
  if (!isRecord(raw) || raw.schema_version !== 1 || raw.provider !== "zai") return undefined;
  const observedAtMs = typeof raw.observed_at === "string" ? Date.parse(raw.observed_at) : NaN;
  if (!Number.isFinite(observedAtMs) || !isRecord(raw.windows)) return undefined;
  const short = snapshotWindow(raw.windows.short);
  const weekly = snapshotWindow(raw.windows.weekly);
  if (short === null || weekly === null || (!short && !weekly)) return undefined;
  const plan = level(raw.plan_level);
  const quota: Quota = {};
  if (plan !== undefined) quota.level = plan;
  if (short) quota.short = short;
  if (weekly) quota.weekly = weekly;
  return { quota, observedAtMs };
}
