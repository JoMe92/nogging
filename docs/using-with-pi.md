# Using Agentsembli SpecForge with Pi

Agentsembli SpecForge is tool-neutral. `AGENTS.md` is the canonical instruction file for
every agent runtime, and the mechanical bridge (`scripts/specforge`) is the same
whichever agent runs it. This page covers what is specific to running the
Agentsembli SpecForge loop from **Pi** (`https://pi.dev/`, package
`@earendil-works/pi-coding-agent`) instead of Claude Code or Codex.

Everything verified below was checked hands-on against the installed
`@earendil-works/pi-coding-agent@0.85.0` package (source and shipped example
extensions), not just pi.dev's docs. Pi moves fast; where a detail is
version-dependent it is called out so you can re-check.

## Prerequisites

In addition to the usual target-repo prerequisites (`bd`/Beads, `python3`,
`git`, and a reachable Dolt for sync):

- **The `pi` CLI on `PATH`.** `scripts/specforge doctor` reports it as
  `NOTE  pi available` / `NOTE  pi not installed; only needed for the Pi agent
  path` — its absence never fails `doctor`, because a Claude/Codex-only repo
  is perfectly valid.
- **Node.js ≥ 22.19.0 to *run* `pi` itself.** This is separate from — and
  newer than — the `Node.js ≥ 18` the SpecForge installer needs; a host can
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
  provider/auth concern, not something SpecForge manages.
- **Trust `.pi/extensions/` once.** Pi only loads project-local
  `.pi/extensions/`, `.pi/prompts/`, and the other `.pi/*` resource
  directories once the project has a standing trust decision, or `--approve`
  is passed for that run. `scripts/specforge session launch --agent pi`
  always passes `--approve` itself (see *Launch authority levels* below), so
  a supervised launch works without any manual trust step — but running `pi`
  yourself, interactively, in this repo will still prompt the first time.
  `scripts/specforge doctor` prints a NOTE naming the fix (`pi --approve` or
  the `/trust` command) when `pi` is present, the guard extension is shipped,
  and no standing trust decision has been recorded yet.

## What the installer places under `.pi/`

`npx github:JoMe92/agentsembli-specforge init` (or `update`) ships two directories,
copied verbatim on every `init`/`update`:

| Path | Behaviour |
| --- | --- |
| `.pi/prompts/{plan,discovery-review,sync-now}.md` | The **workflow prompts** — Pi reads `.pi/prompts/*.md` directly from the repository (confirmed from source: `resource-loader.js` resolves `<repo>/.pi/prompts` literally), so — unlike Codex — **no symlink helper is needed**. |
| `.pi/extensions/specforge-guard.ts` | The **guard extension**: Pi's project-local floor, since Pi ships no native sandbox or execution-policy mechanism of its own. See *The guard extension* below. |

A user's own `.pi/settings.json` or other `.pi/*` content is never touched.

### Launch authority levels

`scripts/specforge session launch --agent pi` resolves `restricted`
(default) / `trusted` (`--full-access`) against
`.specforge/launch-profiles/{restricted,trusted}.pi.toml`. Unlike Claude and
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
otherwise need — left to the operator, not managed by SpecForge). Treat a Pi
session's `restricted` level as weaker than the same word for Claude or
Codex.

## The guard extension — `.pi/extensions/specforge-guard.ts`

Pi extensions can intercept the `tool_call` event before a tool runs — the
direct analogue of Claude's `PreToolUse` hook, and the mechanism this bridge
uses since Pi has no execpolicy-style file. `specforge-guard.ts`:

- denies a shell command (`toolName === "bash"`) matching the SpecForge
  command floor: `sudo`, `rm -rf`/`rm -fr`, `dd`, `mkfs` and its variants,
  `shutdown`, `reboot`, `systemctl`, `chown`, `curl`, `wget`,
  `git push --force`/`-f`/`--force-with-lease`, `git reset --hard`,
  `git clean -f*`, `git filter-branch`;
- denies a write or edit (`toolName === "write"`/`"edit"`) under `openspec/`
  unless `.specforge/locks/openspec.readonly` is absent (a planning session
  is active) — the same sentinel `plan-begin`/`plan-end` toggle for every
  other agent.

It is active at **both** authority levels, always — nothing this bridge
passes to `pi` suppresses or bypasses it, and `trusted` only changes the
launch prompt, never the guard. The matching logic
(`matchesFloor`, `isUnderOpenspec`, `openspecBoundaryOpen`) is exercised
directly, without a live `pi` process, by `scripts/pi-guard.test.sh`.

## How the commands map

| SpecForge command | Claude Code | Codex | Pi |
| --- | --- | --- | --- |
| `/plan` | `.claude/commands/plan.md` | `.codex/prompts/plan.md` | `.pi/prompts/plan.md` |
| `/discovery-review` | `.claude/commands/discovery-review.md` | `.codex/prompts/discovery-review.md` | `.pi/prompts/discovery-review.md` |
| `/sync-now` | `.claude/commands/sync-now.md` | `.codex/prompts/sync-now.md` | `.pi/prompts/sync-now.md` |

The persona and step text are identical across all three; only the invocation
surface and, in `plan.md`, the description of how the `openspec/` write
boundary is actually enforced (the guard extension for Pi, versus a
`PreToolUse` hook for Claude or the filesystem write guard for Codex) differ.
Each is a thin wrapper over `scripts/specforge` — the mechanical steps
(`plan-begin` → discovery review → author → `validate` → `materialize` →
commit as the `planning` writer → `plan-end`; `discoveries` / `--ack`;
`sync --now`) are agent-neutral.

## Resuming a run after a tool switch

Switching to or from Pi mid-run is a supported interruption, exactly like
switching between Claude Code and Codex. The durable state — `git`, `bd` /
Dolt, `openspec/`, `.specforge/state/` — is not tool-specific. So on the next
start, before touching `bd ready`, a resumed or switched session runs
`./scripts/specforge recover` and resolves what it reports with the
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
  scripts/specforge session launch --agent pi \
    --role specialist:<type> --bead <id>
  ```

Either way every specialist boundary rule holds: exactly one already-claimed
Bead, no `openspec/` writes, no claim/close/commit, and plan-relevant findings
are reported back to the Lead Agent as discoveries.

## Known limitations

- **No native sandbox, at either authority level.** See *Launch authority
  levels* above — this is the load-bearing limitation of running SpecForge
  under Pi and is stated here plainly rather than assumed away: `restricted`
  for Pi is floor-only, not network- or filesystem-isolated.
- **No Pi CI job** — there is none, and none is needed: the mechanical CI
  subset (`invariants`, `acceptance`) is already agent-neutral.
- **Skills auto-discovery was not verified for Pi in this change.** Codex's
  `.agents/skills/**/SKILL.md` auto-loading was hands-on confirmed in an
  earlier change; the equivalent for Pi was out of scope here and should not
  be assumed until checked.

## See also

- `AGENTS.md` — the canonical, tool-neutral instruction file (its *Tool notes*
  section has the Claude-vs-Codex-vs-Pi summary).
- `docs/operating-model.md` — roles, the delegation model, session supervision.
- `docs/installation.md` — the installer and what it writes.
