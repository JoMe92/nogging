/**
 * Nogging lifecycle reporter for supervised Pi sessions.
 *
 * Maps Pi's lifecycle events onto `scripts/nogg session emit` so `session
 * watch`, `session send` and the dispatcher see a Pi session as idle,
 * working or waiting for input instead of `unknown` (session-wake design
 * Decision 2). It is inert unless `NOGG_SESSION_NAME` is set, and every failure
 * is swallowed. One thing changes a run: the stop guard (Decision 5) continues
 * an autonomous Lead that would settle with gaps, once per user input. Anything
 * wrong with that check allows the settle.
 *
 * `agent_end` is deliberately not used: a retry, recovery, compaction or
 * queued message can start another run after it. Only `agent_settled` means
 * the run is finished.
 *
 * Plain erasable TypeScript with Node built-ins only, so Node can run it by
 * type stripping and it loads in every supervised session.
 */
import { execFile } from "node:child_process";
import { join } from "node:path";

const LOADED = Symbol.for("nogging.lifecycle.loaded");
const EMIT_TIMEOUT_MS = 3000;
const DRAIN_MS = 1000;
const GUARD_TIMEOUT_MS = 8000;
const STDIN_LIMIT = 60 * 1024;

type Json = Record<string, unknown>;

function lastAssistantMessage(ctx: any): { text: string; error: string } {
	try {
		const branch = ctx?.sessionManager?.getBranch?.();
		if (!Array.isArray(branch)) return { text: "", error: "" };
		for (let i = branch.length - 1; i >= 0; i--) {
			const message = branch[i]?.type === "message" ? branch[i].message : undefined;
			if (message?.role !== "assistant") continue;
			const content = message.content;
			const text = typeof content === "string"
				? content
				: Array.isArray(content)
					? content.filter((p: any) => p?.type === "text" && typeof p.text === "string").map((p: any) => p.text).join("\n")
					: "";
			const failed = message.stopReason === "error" && typeof message.errorMessage === "string";
			return { text, error: failed ? message.errorMessage : "" };
		}
	} catch {
		// A shape Pi changed must not break the session.
	}
	return { text: "", error: "" };
}

function errorKind(detail: string): string {
	return /rate.?limit|too many requests|\b429\b|quota|usage limit/i.test(detail) ? "rate_limit" : "error";
}

export default function (pi: any) {
	const name = process.env.NOGG_SESSION_NAME;
	const root = process.env.NOGG_SESSION_ROOT;
	if (!name) return;
	// A Pi child of a Claude or Codex session inherits its environment and must
	// not answer for it.
	const agent = process.env.NOGG_SESSION_AGENT;
	if (agent && agent !== "pi") return;
	const globals = globalThis as Record<symbol, unknown>;
	if (globals[LOADED]) return;
	globals[LOADED] = true;

	let running = false;
	let errored = false;
	// In memory on purpose: Pi offers no stop_hook_active, and this bound must not
	// depend on anything a broken check could lose.
	let guarded = false;

	// Emits run one after another so events append in the order Pi fired them;
	// a stuck child delays only later events, by at most EMIT_TIMEOUT_MS each.
	let tail: Promise<void> = Promise.resolve();
	const emit = (event: string, payload?: Json) => {
		if (!root) return;
		tail = tail.then(() => new Promise<void>((resolve) => {
			try {
				const child = execFile(
					join(root, "scripts", "nogg"),
					["session", "emit", event],
					{ timeout: EMIT_TIMEOUT_MS, killSignal: "SIGKILL", windowsHide: true, env: process.env },
					() => resolve(),
				);
				child.on("error", () => resolve());
				child.stdin?.on("error", () => {});
				child.stdin?.end(payload ? JSON.stringify(payload).slice(0, STDIN_LIMIT) : "");
				// A stuck child must never hold Pi open on exit.
				child.stdout?.unref?.();
				child.stderr?.unref?.();
				child.unref();
			} catch {
				// Observability never affects the session.
				resolve();
			}
		}));
	};

	// The fixed continuation text, or "" for anything but a clear answer.
	const guardMessage = () => new Promise<string>((resolve) => {
		if (!root) return resolve("");
		try {
			const child = execFile(
				join(root, "scripts", "nogg"),
				["session", "completion-check", "--json"],
				{ timeout: GUARD_TIMEOUT_MS, killSignal: "SIGKILL", windowsHide: true, env: process.env },
				// Exit 1 only means "gaps": stdout is what counts.
				(_error, stdout) => {
					try {
						const message = JSON.parse(String(stdout)).message;
						resolve(typeof message === "string" ? message : "");
					} catch {
						resolve("");
					}
				},
			);
			child.on("error", () => resolve(""));
			child.stdin?.on("error", () => {});
			child.stdin?.end();
		} catch {
			resolve("");
		}
	});

	// Give queued events a short, bounded chance to land before Pi exits.
	const drain = () => new Promise<void>((resolve) => {
		const timer = setTimeout(resolve, DRAIN_MS);
		timer.unref();
		tail.then(() => { clearTimeout(timer); resolve(); });
	});

	const on = (event: string, handler: (event: any, ctx: any) => unknown) => {
		pi.on(event, async (e: any, ctx: any) => {
			try {
				return await handler(e, ctx);
			} catch {
				// Handler errors never reach Pi.
				return undefined;
			}
		});
	};

	on("input", () => {
		guarded = false;
	});

	on("agent_start", () => {
		running = true;
		errored = false;
		emit("turn_start");
	});

	on("agent_before_settle", async (event, ctx) => {
		const last = lastAssistantMessage(ctx);
		if (event?.outcome === "error") {
			errored = true;
			emit("turn_error", { error: errorKind(last.error), last_assistant_message: last.text });
			return undefined;
		}
		if (event?.outcome !== "completed" || guarded || event?.continue) return undefined;
		const message = await guardMessage();
		if (!message) return undefined;
		guarded = true;
		emit("guard_continue", { last_assistant_message: last.text });
		// A handler's entries replace the chain, so keep what others proposed.
		const entry = { type: "custom_message", customType: "nogging-stop-guard", content: message, display: true };
		return { continue: true, entries: [...(event?.entries ?? []), entry] };
	});

	on("agent_settled", (event, ctx) => {
		running = false;
		if (errored) {
			// turn_error already ended the run and keeps a `limit` state a turn_end would erase.
			errored = false;
			return;
		}
		emit("turn_end", { last_assistant_message: lastAssistantMessage(ctx).text });
	});

	on("ui_prompt_start", () => emit("needs_input"));

	on("ui_prompt_end", () => emit(running ? "turn_start" : "turn_end"));

	on("session_shutdown", async (event) => {
		// A reload, new session, resume or fork keeps the process alive.
		if (event?.reason === undefined || event.reason === "quit") emit("session_end");
		delete globals[LOADED];
		await drain();
	});
}
