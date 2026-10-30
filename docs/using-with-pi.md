# Using Nogging with Pi

Nogging is tool-neutral. `AGENTS.md` is the canonical instruction file for
every agent runtime, and the mechanical bridge (`scripts/nogg`) is the same
whichever agent runs it. This page is for users who run the Nogging loop from
**Pi** (`https://pi.dev/`, package `@earendil-works/pi-coding-agent`) instead
of Claude Code or Codex, and covers what is specific to that setup.

Everything verified below was checked hands-on against the installed
`@earendil-works/pi-coding-agent@0.85.0` package (source and shipped example
extensions), not just pi.dev's docs. Pi moves fast; where a detail is
version-dependent it is called out so you can re-check.

## Prerequisites

In addition to the usual target-repo prerequisites (`bd`/Beads, `python3`,
`git`, and a reachable Dolt for sync):

- **The `pi` CLI on `PATH`.** `scripts/nogg doctor` reports it as
  `NOTE  pi available` / `NOTE  pi not installed; only needed for the Pi agent
  path` — its absence never fails `doctor`, because a Claude/Codex-only repo
  is perfectly valid.
- **Node.js ≥ 22.19.0 to *run* `pi` itself.** This is separate from — and
  newer than — the `Node.js ≥ 18` the Nogging installer needs; a host can
  satisfy the installer's requirement while still being too old to run `pi`.
  `pi` fails immediately on an older Node with a `SyntaxError` (a built-in
  module export it needs, `node:fs`'s `globSync`, only exists from Node
  22.19+). If the system Node is too old, install a separate, newer Node for
  `pi` alone (a portable per-user install works fine; it does not need to be
  the system Node).
- **A configured model provider.** `pi` needs a provider/API key configured
  (`pi auth …`) before a non-interactive launch can do any real work — with
  none configured, `session launch --agent pi` starts the process but it fails
  immediately with "No API key found for the selected model". This is a
  provider/auth concern, not something Nogging manages.
- **Supervised guard activation requires no standing trust change.** The wrapper
  passes the absolute guard path through `--extension` and uses run-scoped
  `--approve` for project resources. It refuses to start if the guard is missing.
  It does not modify Pi's trust store. Standalone Pi requires run approval or an
  existing project trust decision to discover local resources. `doctor` names
  the guard and the shared state locations.

## What the installer places under `.pi/`

`npx github:JoMe92/nogging#<tag> init` (or `update`) ships two directories,
copied verbatim on every `init`/`update`:

| Path | Behaviour |
| --- | --- |
| `.pi/prompts/{plan,discovery-review,sync-now}.md` | The **workflow prompts** — Pi reads `.pi/prompts/*.md` directly from the repository (confirmed from source: `resource-loader.js` resolves `<repo>/.pi/prompts` literally), so — unlike Codex — **no symlink helper is needed**. |
| `.pi/extensions/nogging-guard.ts` | The **guard extension**: Pi's project-local floor, since Pi ships no native sandbox or execution-policy mechanism of its own. See *The guard extension* below. |
| `.pi/extensions/nogging-lifecycle.ts` | The **lifecycle extension**: reports a supervised session's turns so `session watch` and `session send` can tell `working` from `idle`. See *The lifecycle extension* below. |

A user's own `.pi/settings.json` or other `.pi/*` content is never touched.

### Launch authority levels

`scripts/nogg session launch --agent pi` resolves `restricted`
(default) / `trusted` (`--full-access`) against
`.nogging/launch-profiles/{restricted,trusted}.pi.toml`. Unlike Claude and
Codex, **the two levels are not a sandbox split** — Pi has none to split:

| Level | Selected by | Guard extension | Network / filesystem sandbox | Launch prompt |
| --- | --- | --- | --- | --- |
| **restricted** | default | active | **none** | default (no autonomous claim) |
| **trusted** | `--full-access` | active (never disabled) | **none** | autonomous |

Both `.pi.toml` files may optionally name a `provider`/`model` pair to forward
to `pi --provider`/`pi --model`; neither key is required. **Read this
honestly:** for `claude` and `codex`, `restricted` denies outbound network and
enforces a filesystem/approval sandbox. For `pi`, `restricted` enforces only
the command floor and the `openspec/` write boundary — there is no network or
filesystem isolation at either level, because Pi's own built-in tools run
shell commands and file writes with the full permissions of the `pi` process,
and nothing in this bridge can restrict that further short of an external
container (a genuine option, but a new infra dependency this repo does not
otherwise need — left to the operator, not managed by Nogging). Treat a Pi
session's `restricted` level as weaker than the same word for Claude or
Codex.

## The lifecycle extension — `.pi/extensions/nogging-lifecycle.ts`

Pi has no hook file, so a supervised session reports its own lifecycle through
an extension that `session launch` loads beside the guard, with `--extension`.
It lives in `.pi/extensions/`, not under `.pi/nogging/`, because it must load in
every supervised session. It maps Pi's events onto `scripts/nogg session emit`:

| Pi event | Reported as | State in `watch` |
| --- | --- | --- |
| `agent_start` | `turn_start` | `working` |
| `agent_settled` | `turn_end`, with the last assistant message as the excerpt | `idle` |
| `agent_before_settle` with `outcome: "error"` | `turn_error` | `limit` for a rate limit, else `idle` |
| `agent_before_settle` with gaps, in an autonomous Lead | `guard_continue`, and one more model request | `working` |
| `ui_prompt_start` | `needs_input` | `needs_input` |
| `ui_prompt_end` | `turn_start` during a run, else `turn_end` | `working` or `idle` |
| `session_shutdown` (quit) | `session_end` | `ended` |

That second `agent_before_settle` row is the stop guard: it asks `session
completion-check` and, on gaps, appends the fixed message and continues the run.
It continues at most once per user input, kept in the extension's memory, and any
failure of the check, including a stuck child, lets the run settle.

`agent_end` is never used as completion: a retry, recovery, compaction or queued
message can start another run after it, so only `agent_settled` means finished.
The extension does nothing unless `NOGG_SESSION_NAME` is set, so standalone Pi is
unaffected. It uses only Node built-ins, runs each `session emit` as a
timeout-bounded child that cannot hold Pi open, and swallows its own errors.
A missing file only warns at launch: observability never blocks a session, and
`watch` then falls back to herdr's status or the pane (`unknown` when neither
exists). On herdr, `agent_status` joins the evidence, so a Pi session is
classified on tmux and herdr alike.

## The guard extension — `.pi/extensions/nogging-guard.ts`

Pi extensions can intercept the `tool_call` event before a tool runs — the
direct analogue of Claude's `PreToolUse` hook, and the mechanism this bridge
uses since Pi has no execpolicy-style file. `nogging-guard.ts`:

- denies a shell command (`toolName === "bash"`) matching the Nogging
  command floor: `sudo`, `rm -rf`/`rm -fr`, `dd`, `mkfs` and its variants,
  `shutdown`, `reboot`, `systemctl`, `chown`, `curl`, `wget`,
  `git push --force`/`-f`/`--force-with-lease`, `git reset --hard`,
  `git clean -f*`, `git filter-branch`;
- denies a write or edit (`toolName === "write"`/`"edit"`) under `openspec/`
  unless the role is exactly `planning`, the main checkout has a fresh valid
  planning lock, and neither canonical nor legacy local closed sentinel exists.
  Missing, malformed, unreadable or unsupported state denies authorization.
  The canonical config supplies `planning_lock_ttl_seconds` (default 7200).
  Execution roles stay read-only even while another planning session is open.
  Paths are normalized from the checkout root, including nested cwd, `..`,
  absolute paths and existing symlinks. Standalone Pi defaults to execution;
  an explicitly authorized manual planning process needs
  `NOGG_SESSION_ROLE=planning` in addition to `plan-begin`.

It is active at **both** authority levels, always — nothing this bridge
passes to `pi` suppresses or bypasses it, and `trusted` only changes the
launch prompt, never the guard. The matching logic
(`matchesFloor`, `isUnderOpenspec`, `openspecBoundaryOpen`) is exercised
directly, without a live `pi` process, by `scripts/pi-guard.test.sh`.

## How the commands map

| Nogging command | Claude Code | Codex | Pi |
| --- | --- | --- | --- |
| `/plan` | `.claude/commands/plan.md` | `.codex/prompts/plan.md` | `.pi/prompts/plan.md` |
| `/discovery-review` | `.claude/commands/discovery-review.md` | `.codex/prompts/discovery-review.md` | `.pi/prompts/discovery-review.md` |
| `/sync-now` | `.claude/commands/sync-now.md` | `.codex/prompts/sync-now.md` | `.pi/prompts/sync-now.md` |

The persona and step text are identical across all three; only the invocation
surface and, in `plan.md`, the description of how the `openspec/` write
boundary is actually enforced (the guard extension for Pi, versus a
`PreToolUse` hook for Claude or the filesystem write guard for Codex) differ.
Each is a thin wrapper over `scripts/nogg` — the mechanical steps
(`plan-begin` → discovery review → author → `validate` → commit as the
`planning` writer → `materialize` → wire dependencies → integrate →
`plan-end` from the planning worktree → `worktree cleanup` from the surviving
canonical checkout; `discoveries` /
`--ack`; `sync --now`) are agent-neutral. `plan-end` always precedes worktree
retirement: run it from the planning worktree, then retire the worktree with
`worktree cleanup <record>` from the surviving canonical checkout. If cleanup
refuses, hand off with `./scripts/nogg session stop <name>`, then `./scripts/nogg worktree cleanup <record>` from the canonical checkout.

## Resuming a run after a tool switch

Switching to or from Pi mid-run is a supported interruption, exactly like
switching between Claude Code and Codex. The durable state — `git`, `bd` /
Dolt, `openspec/`, `.nogging/state/` — is not tool-specific. So on the next
start, before touching `bd ready`, a resumed or switched session runs
`./scripts/nogg recover` and resolves what it reports with the
[`failure-recovery.md`](failure-recovery.md) § "Resuming an interrupted run"
playbook — exactly as `AGENTS.md` § "Resuming a run" describes. The protocol
is tool-neutral; nothing about it is Pi-specific.

## Specialists

Pi has **no in-process subagent mechanism** — there is no Pi equivalent of
Claude Code's Task tool, and the six `.claude/agents/*.md` specialists are not
ported. A Pi Lead Agent therefore either:

- does the isolated implementation or review slice **inline**, under the same
  specialist constraints; or
- when the operator wants a separate observable process, starts one with:

  ```bash
  scripts/nogg session launch --agent pi \
    --role specialist:<type> --bead <id>
  ```

Either way every specialist boundary rule holds: exactly one already-claimed
Bead, no `openspec/` writes, no claim/close/commit, and plan-relevant findings
are reported back to the Lead Agent as discoveries.

## Known limitations

- **herdr backend.** Pi can run with `--backend herdr`. It passed a live run
  on 2026-10-27: launch on herdr, kickoff, a complete Bead with PR, and log
  capture — including reading logs split by rotation (#304).
- **No native sandbox, at either authority level.** See *Launch authority
  levels* above — this is the load-bearing limitation of running Nogging
  under Pi and is stated here plainly rather than assumed away: `restricted`
  for Pi is floor-only, not network- or filesystem-isolated.
- **No Pi CI job** — there is none, and none is needed: the mechanical CI
  subset (`invariants`, `acceptance`) is already agent-neutral.
- **Skills auto-discovery is not verified for Pi.** Codex's
  `.agents/skills/**/SKILL.md` auto-loading was confirmed hands-on, but the
  equivalent for Pi was not checked and should not be assumed until it is.

## See also

- `AGENTS.md` — the canonical, tool-neutral instruction file (its *Tool notes*
  section has the Claude-vs-Codex-vs-Pi summary).
- [Operating model](operating-model.md) — roles, the delegation model, session supervision.
- [Installation guide](https://jome92.github.io/nogging/installation/) — the installer and what it writes.
- [Using Nogging with Claude Code](https://jome92.github.io/nogging/using-with-claude-code/) — the same
  loop from the default agent.
