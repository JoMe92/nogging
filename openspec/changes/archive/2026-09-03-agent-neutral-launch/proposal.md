# Run a supervised session with Codex, not only Claude Code

## Why

`scripts/specforge session launch` starts one agent binary: `scripts/session-launch`
ends with `exec claude …`. Every part around it — the tmux server, the durable
record, the append-only log, `list`/`attach`/`stop`/`cleanup`, the profile
resolution, the command floor — is agent-neutral, but the agent itself is
hard-wired.

`docs/source/codex-support-analysis.md` (coupling points C7/C8) identified this
as the highest-leverage single change for Codex support: parameterise the agent
binary and map the tool-neutral authority level (`restricted` / `trusted`) onto
Codex's `--sandbox` / `--ask-for-approval` model instead of a Claude
`permissions` file. Doing this also unlocks the Codex specialist story — a
specialist run under Codex is `session launch --agent codex --role
specialist:<type>`, an observed out-of-process session, since Codex has no
in-process Task tool.

This is the first change of the Codex-support epic. `tool-agnostic-write-boundary`
and `codex-onboarding` build on it.

## What Changes

- **`session launch --agent <claude|codex>`.** Default from a new
  `.specforge/config.json` key `session_agent` (default `claude`). The session
  metadata record gains an `agent` field and `session list` gains an `AGENT`
  column.
- **Authority levels become tool-neutral.** `restricted` and `trusted` (and a
  supplied path) resolve per agent: for `claude`, to the existing
  `.specforge/launch-profiles/<level>.json` Claude settings file, unchanged; for
  `codex`, to a Codex launch spec — sandbox mode, approval policy, and network
  setting — shipped as `.specforge/launch-profiles/<level>.codex.toml`.
- **`scripts/session-launch` dispatches on `--agent`.** The `claude` branch is
  byte-for-byte today's behaviour. The `codex` branch starts
  `codex --cd <cwd> --sandbox <mode> --ask-for-approval <policy> [-c …]` with the
  launch prompt as the leading instruction, under the SpecForge tmux server, the
  same pipe-pane log, the same lifecycle.
- **The command floor applies to both.** For `codex`, `session launch` runs the
  agent with the repo's `.codex/rules/` execpolicy directory active so the floor
  denials (no `git push`, no remote Dolt sync, no destructive shell) hold; the
  `.codex/rules/specforge.rules` file itself is shipped by `codex-onboarding`.
- **`--full-access` maps per agent** — `claude`: `trusted` + `autonomous` as
  today; `codex`: `--sandbox workspace-write --ask-for-approval never` +
  `autonomous`.
- **`scripts/specforge doctor` checks for `codex`** — a warning when absent,
  like `dolt`, never a failure.
- The `autonomous` / `no-autonomous-claim` prompt files are already tool-neutral
  prose; they are passed to Claude via `--append-system-prompt` and to Codex as
  the leading `[PROMPT]`.

## Capabilities

### New Capabilities

- `agent-neutral-launch`: a supervised session runs either Claude Code or Codex,
  selected per launch or by config default, under the same authority levels,
  command floor, record, log and lifecycle; the agent in use is recorded and
  listed.

### Modified Capabilities

<!-- none -->

## Impact

- Modified code: `scripts/specforge` (`session_launch`, `resolved_launch_pair` /
  a new Codex-aware resolver, `session_list` + `_profile_display` sibling for the
  agent column, the `session launch` argparser, `doctor`, the new config key),
  `scripts/session-launch` (agent dispatch).
- New files: `.specforge/launch-profiles/restricted.codex.toml`,
  `.specforge/launch-profiles/trusted.codex.toml`.
- Modified: `.specforge/config.json` (`session_agent`), `bin/lib/manifest.js` +
  `package.json` `files` (the two `*.codex.toml` fragments — the
  `.specforge/launch-profiles/` dir is already shipped), `scripts/session.test.sh`,
  `docs/running-work-in-sessions.md`, `docs/operating-model.md`.
- Behavioural change: none by default. `--agent codex` and `session_agent =
  "codex"` are the only ways to change what starts.
- Depends on: nothing. `tool-agnostic-write-boundary` and `codex-onboarding`
  depend on this.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
