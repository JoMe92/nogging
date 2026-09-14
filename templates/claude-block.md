## Agentsembli SpecForge

This repository uses the Agentsembli SpecForge operating model. **`AGENTS.md` is the
canonical instruction file** — read it (and `docs/nogging/`) for the hard
rules, the write boundary, and the workflow. This block carries only the one
detail specific to Claude Code.

- **Claude-only:** a `PreToolUse` hook (`scripts/hooks/pre-tool-use-openspec-guard`,
  wired in `.claude/settings.json`) blocks `Edit`/`Write` under `openspec/`
  unless the planning lock is held. It is a fast in-editor backstop to the
  tool-neutral write boundary described in `AGENTS.md`; the boundary holds
  without it.
- **Claude-only:** the **Orchestration Agent** — the always-on
  `nogg-orchestrator-<slug>` session above Planning and the Main Worker,
  orchestrate-only by default, floor- and boundary-lifted for `--role
  orchestrator`, reachable from a phone via Remote Control. `AGENTS.md` *The
  Orchestration Agent* and `docs/nogging/operating-model.md` have the persona
  and its scope; `scripts/nogg orchestrator {run,status,stop,restart}` and
  `.claude/commands/orchestrate.md` drive it.

Update SpecForge with `npx github:JoMe92/agentsembli-specforge update`.
