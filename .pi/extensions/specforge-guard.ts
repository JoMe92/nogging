/**
 * SpecForge command-floor and openspec/ write-boundary guard for Pi.
 *
 * Pi ships no native sandbox or execution-policy mechanism (unlike Codex's
 * execpolicy directory or Claude's PreToolUse hook), so this project-local
 * extension IS the floor for a Pi-supervised SpecForge session: it
 * intercepts every `tool_call` event and denies a shell command matching
 * the SpecForge command-floor patterns, or a write/edit under `openspec/`
 * while the write boundary is closed. Loads only once this project is
 * trusted (`--approve` or `/trust`), since `.pi/extensions/` is one of the
 * trust-gated resource directories.
 *
 * Deliberately over-inclusive on the shell-command matching: a false
 * positive just makes an operator explain themselves; a false negative is
 * an actual safety gap. None of these patterns attempt full shell parsing.
 */
import { resolve, sep } from "node:path";
import { existsSync } from "node:fs";
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

export function isUnderOpenspec(inputPath: string, cwd: string): boolean {
	const openspecRoot = resolve(cwd, "openspec");
	const resolved = resolve(cwd, inputPath);
	return resolved === openspecRoot || (resolved + sep).startsWith(openspecRoot + sep);
}

export function openspecBoundaryOpen(cwd: string): boolean {
	// Mirrors scripts/nogg's SENTINEL: presence of
	// .nogging/locks/openspec.readonly means CLOSED (read-only); absence
	// means a planning session is active and the boundary is OPEN.
	return !existsSync(resolve(cwd, ".nogging/locks/openspec.readonly"));
}

export default function (pi: ExtensionAPI) {
	pi.on("tool_call", async (event, ctx) => {
		if (event.toolName === "bash") {
			const hit = matchesFloor(event.input.command as string);
			if (hit) {
				if (ctx.hasUI) ctx.ui.notify(`SpecForge floor blocked: ${hit}`, "warning");
				return { block: true, reason: `SpecForge floor: command matches "${hit}"` };
			}
			return undefined;
		}
		if (event.toolName === "write" || event.toolName === "edit") {
			const path = event.input.path as string;
			if (isUnderOpenspec(path, ctx.cwd) && !openspecBoundaryOpen(ctx.cwd)) {
				if (ctx.hasUI) ctx.ui.notify(`Blocked ${event.toolName} under openspec/: ${path}`, "warning");
				return { block: true, reason: "openspec/ is read-only outside a planning session (SpecForge write boundary)" };
			}
			return undefined;
		}
		return undefined;
	});
}
