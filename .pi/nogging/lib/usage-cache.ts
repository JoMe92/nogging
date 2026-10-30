// Shared usage-snapshot cache for Nogging's optional Pi extensions.
//
// The directory is the one Claude's status line already writes claude.json
// into: $XDG_CACHE_HOME/nogging/usage, or ~/.cache/nogging/usage. It is
// created 0700 and every file is written 0600 through a temporary file and a
// rename, so a reader never sees a half-written snapshot. A read never throws:
// a missing, unreadable or malformed file is `undefined`.
//
// Runtime imports are node: built-ins only and no Pi import is needed, so this
// loads under Pi's jiti and Node's type stripping unchanged.
import { chmodSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

export type CacheEnv = { XDG_CACHE_HOME?: string; HOME?: string };

export function usageCacheDir(env: CacheEnv = process.env): string {
  const xdg = env.XDG_CACHE_HOME;
  const base = xdg ? xdg : path.join(env.HOME ? env.HOME : homedir(), ".cache");
  return path.join(base, "nogging", "usage");
}

export function usageCachePath(name: string, env: CacheEnv = process.env): string {
  if (!name || name !== path.basename(name) || name === "." || name === "..") {
    throw new Error(`invalid usage cache file name: ${JSON.stringify(name)}`);
  }
  return path.join(usageCacheDir(env), name);
}

export function readUsageCache(name: string, env: CacheEnv = process.env): unknown {
  try {
    return JSON.parse(readFileSync(usageCachePath(name, env), "utf8"));
  } catch {
    return undefined;
  }
}

export function writeUsageCache(name: string, data: unknown, env: CacheEnv = process.env): string {
  const file = usageCachePath(name, env);
  const dir = path.dirname(file);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  // mkdir leaves an existing directory's mode alone; tighten it.
  chmodSync(dir, 0o700);
  const tmp = path.join(dir, `.${name}.${process.pid}.${Date.now()}.tmp`);
  try {
    writeFileSync(tmp, JSON.stringify(data), { mode: 0o600 });
    // The mode argument is masked by umask and ignored for an existing file.
    chmodSync(tmp, 0o600);
    renameSync(tmp, file);
  } catch (err) {
    rmSync(tmp, { force: true });
    throw err;
  }
  return file;
}
