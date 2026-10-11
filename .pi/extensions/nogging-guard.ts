/**
 * Nogging command-floor and openspec/ write-boundary guard for Pi.
 *
 * Pi ships no native sandbox or execution-policy mechanism (unlike Codex's
 * execpolicy directory or Claude's PreToolUse hook), so this project-local
 * extension IS the floor for a Pi-supervised Nogging session: it
 * intercepts every `tool_call` event and denies a shell command matching
 * the Nogging command-floor patterns, or a write/edit under `openspec/`
 * while the write boundary is closed. Supervised launches explicitly load
 * this extension; project discovery in standalone Pi requires run approval.
 *
 * Deliberately over-inclusive on the shell-command matching: a false
 * positive just makes an operator explain themselves; a false negative is
 * an actual safety gap. None of these patterns attempt full shell parsing.
 */
import { dirname, resolve, sep } from "node:path";
import { hostname } from "node:os";
import { lstatSync, readFileSync, realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

function hasShortFlagChar(cmd: string, ch: string): boolean {
	// Matches a short-option token containing `ch`, e.g. -rf, -fr, -Rf, -f.
	return new RegExp(`(^|\\s)-[a-zA-Z]*${ch}[a-zA-Z]*(\\s|$)`, "i").test(cmd);
}

export function isRmForceRecursive(cmd: string): boolean {
	if (!/\brm\b/.test(cmd)) return false;
	const recursive = hasShortFlagChar(cmd, "r") || /--recursive\b/.test(cmd);
	const force = hasShortFlagChar(cmd, "f") || /--force\b/.test(cmd);
	return recursive && force;
}

export function isGitPushForce(cmd: string): boolean {
	if (!/\bgit\b/.test(cmd) || !/\bpush\b/.test(cmd)) return false;
	return /--force(-with-lease)?\b/.test(cmd) || hasShortFlagChar(cmd, "f");
}

export function isGitCleanForce(cmd: string): boolean {
	if (!/\bgit\s+clean\b/.test(cmd)) return false;
	// git clean with no force flag refuses to do anything (dry-run by
	// default), so any WORKING invocation necessarily includes -f/--force
	// somewhere in its flags — matching the force flag alone is sufficient,
	// no need to special-case -fdx vs -fd vs -xfd.
	return hasShortFlagChar(cmd, "f") || /--force\b/.test(cmd);
}

const FLOOR_PATTERNS: Array<{ name: string; test: (cmd: string) => boolean }> = [
	{ name: "sudo", test: (c) => /\bsudo\b/.test(c) },
	{ name: "rm -rf/-fr", test: isRmForceRecursive },
	{ name: "dd", test: (c) => /\bdd\b/.test(c) },
	{ name: "mkfs", test: (c) => /\bmkfs(\.\w+)?\b/.test(c) },
	{ name: "shutdown", test: (c) => /\bshutdown\b/.test(c) },
	{ name: "reboot", test: (c) => /\breboot\b/.test(c) },
	{ name: "systemctl", test: (c) => /\bsystemctl\b/.test(c) },
	{ name: "chown", test: (c) => /\bchown\b/.test(c) },
	{ name: "curl", test: (c) => /\bcurl\b/.test(c) },
	{ name: "wget", test: (c) => /\bwget\b/.test(c) },
	{ name: "git push --force", test: isGitPushForce },
	{ name: "git reset --hard", test: (c) => /\bgit\b/.test(c) && /\breset\b/.test(c) && /--hard\b/.test(c) },
	{ name: "git clean -f", test: isGitCleanForce },
	{ name: "git filter-branch", test: (c) => /\bgit\s+filter-branch\b/.test(c) },
];

export function matchesFloor(command: string): string | undefined {
	return FLOOR_PATTERNS.find((p) => p.test(command))?.name;
}

function repositoryState(cwd: string) {
	const helper = resolve(dirname(fileURLToPath(import.meta.url)), "../../scripts/nogg");
	const env = { ...process.env };
	delete env.NOGGING_ROOT;
	return JSON.parse(execFileSync("python3", [helper, "repo-state", "--cwd", cwd],
		{ encoding: "utf8", env, stdio: ["ignore", "pipe", "pipe"], timeout: 5000 }));
}

function physicalPath(path: string): string {
	try { return realpathSync(path); }
	catch (error) {
		if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
		const parent = dirname(path);
		if (parent === path) throw error;
		return resolve(physicalPath(parent), path.slice(parent.length + 1));
	}
}

export function isUnderOpenspec(inputPath: string, cwd: string): boolean {
	try {
		const state = repositoryState(cwd);
		const target = physicalPath(resolve(cwd, inputPath));
		if (!Array.isArray(state.checkout_roots) || !state.checkout_roots.length) throw new Error("missing checkout roots");
		return state.checkout_roots.some((root: string) => {
			if (typeof root !== "string") throw new Error("invalid repository root");
			const spec = physicalPath(resolve(root, "openspec"));
			return target === spec || target.startsWith(spec + sep);
		});
	} catch {
		// Unknown layout or unreadable path cannot establish safe write scope.
		return true;
	}
}

export function openspecBoundaryOpen(cwd: string, role = process.env.NOGG_SESSION_ROLE ?? "execution"): boolean {
	// Reuse the CLI's canonical Git/worktree resolver. An absent local locks
	// directory must never hide a closed boundary in the main checkout.
	if (role !== "planning") return false;
	try {
		const state = repositoryState(cwd);
		if (typeof state.locks_dir !== "string" || typeof state.config_path !== "string") return false;
		for (const sentinel of new Set([resolve(state.locks_dir, "openspec.readonly"),
			resolve(cwd, ".nogging/locks/openspec.readonly")])) {
			try {
				lstatSync(sentinel);
				return false;
			} catch (error) {
				if (!error || typeof error !== "object" || !("code" in error) || error.code !== "ENOENT") return false;
			}
		}
		const config = JSON.parse(readFileSync(state.config_path, "utf8"));
		if (!config || typeof config !== "object" || Array.isArray(config)) return false;
		const ttl = config.planning_lock_ttl_seconds === undefined ? 7200 : config.planning_lock_ttl_seconds;
		if (typeof ttl !== "number" || !Number.isFinite(ttl) || ttl <= 0) return false;
		const lock = JSON.parse(readFileSync(resolve(state.locks_dir, "planning.lock"), "utf8"));
		if (!lock || typeof lock !== "object" || Array.isArray(lock)
			|| !Number.isInteger(lock.pid) || lock.pid <= 0
			|| typeof lock.host !== "string" || !lock.host.trim()
			|| typeof lock.created_at !== "string"
			|| !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(lock.created_at)) return false;
		if (lock.session_name !== undefined) {
			if (lock.session_name !== process.env.NOGG_SESSION_NAME
				|| lock.session_root !== resolve(process.env.NOGG_SESSION_ROOT ?? state.main_checkout)
				|| typeof lock.pid_start !== "string") return false;
			const sessionConfig = JSON.parse(readFileSync(resolve(lock.session_root, ".nogging/config.json"), "utf8"));
			const session = JSON.parse(readFileSync(resolve(lock.session_root,
				sessionConfig.session_state_dir ?? ".nogging/state/sessions", lock.session_name + ".json"), "utf8"));
			if (lock.host !== hostname() || session.host !== lock.host
				|| session.name !== lock.session_name || session.role !== "planning"
				|| !["starting", "running", "idle"].includes(session.state)
				|| session.session_pid !== lock.pid || session.session_pid_start !== lock.pid_start
				|| resolve(session.working_dir) !== resolve(state.checkout_root)) return false;
			const stat = readFileSync(`/proc/${lock.pid}/stat`, "utf8");
			if (stat.slice(stat.lastIndexOf(")") + 2).trim().split(/\s+/)[19] !== lock.pid_start) return false;
		} else if (process.env.NOGG_SESSION_NAME) return false;
		const created = Date.parse(lock.created_at);
		const age = Date.now() - created;
		return Number.isFinite(created) && age >= 0 && age < ttl * 1000;
	} catch {
		return false;
	}
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName === "bash") {
			const hit = matchesFloor(event.input.command as string);
			if (hit) {
				if (ctx.hasUI) ctx.ui.notify(`Nogging floor blocked: ${hit}`, "warning");
				return { block: true, reason: `Nogging floor: command matches "${hit}"` };
			}
			return undefined;
		}
		if (event.toolName === "write" || event.toolName === "edit") {
			const path = event.input.path as string;
			let allowed = openspecBoundaryOpen(ctx.cwd);
			if (allowed && process.env.NOGG_SESSION_NAME) {
				try {
					const state = repositoryState(ctx.cwd);
					const target = physicalPath(resolve(ctx.cwd, path));
					const own = physicalPath(resolve(state.checkout_root, "openspec"));
					allowed = target === own || target.startsWith(own + sep);
				} catch { allowed = false; }
			}
			if (isUnderOpenspec(path, ctx.cwd) && !allowed) {
				if (ctx.hasUI) ctx.ui.notify(`Blocked ${event.toolName} under openspec/: ${path}`, "warning");
				return { block: true, reason: "openspec/ is read-only outside a planning session (Nogging write boundary)" };
			}
			return undefined;
		}
		return undefined;
	});
}
