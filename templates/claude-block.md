## SpecForge

This repository uses the SpecForge operating model. **`AGENTS.md` is the
canonical instruction file** — read it (and `docs/specforge/`) for the hard
rules, the write boundary, and the workflow. This block carries only the one
detail specific to Claude Code.

- **Claude-only:** a `PreToolUse` hook (`scripts/hooks/pre-tool-use-openspec-guard`,
  wired in `.claude/settings.json`) blocks `Edit`/`Write` under `openspec/`
  unless the planning lock is held. It is a fast in-editor backstop to the
  tool-neutral write boundary described in `AGENTS.md`; the boundary holds
  without it.

Update SpecForge with `npx github:JoMe92/specforge update`.
