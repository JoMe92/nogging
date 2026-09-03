# Using SpecForge with OpenAI Codex

SpecForge is tool-neutral. `AGENTS.md` is the canonical instruction file for
every agent runtime, and the mechanical bridge (`scripts/specforge`) is the same
whichever agent runs it. This page covers what is specific to running the loop
from **OpenAI Codex** instead of Claude Code.

> The rest of this document (prerequisites, the full `.codex/` payload, the
> command mapping, the specialist model, and the known limitations) is filled in
> by TASK-COB-009. The section below records the skill-consumption finding from
> TASK-COB-008.

## Skills

Codex auto-loads agent skills, and — verified against **codex-cli 0.148.0** — it
scans **`.agents/skills/**/SKILL.md` from the working directory up to the repo
root** (as well as `.codex/skills/`, `$CODEX_HOME/skills/`, `/etc/codex/skills`,
and its bundled system skills).

SpecForge already ships its skills under `.agents/skills/` — the same directory
Claude Code reads — so **nothing extra is installed for Codex and no
`.codex/skills/` mirror is needed**. The OpenSpec helper skills
(`openspec-propose`, `openspec-apply-change`, `openspec-explore`,
`openspec-archive-change`, `openspec-sync-specs`, `openspec-update-change`) and
the `beads` skill are available in a Codex session exactly as they are in Claude
Code, discovered automatically or invoked by name with `$openspec-propose` etc.

The skills are guidance, not a hard dependency: a Codex operator can equally run
the underlying `scripts/specforge` steps by hand.
