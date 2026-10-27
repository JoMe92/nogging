# Project identity

This document is the canonical identity statement for the first public
Nogging release.

## Canonical project

- Display name: **Nogging**
- Repository: <https://github.com/JoMe92/nogging>
- Documentation: the repository `README.md` and `docs/` directory
- Support: <https://github.com/JoMe92/nogging/issues>
- Security reports: GitHub private vulnerability reporting for
  <https://github.com/JoMe92/nogging/security>
- Command and package slug: `nogg`
- Installer entry point: `npx github:JoMe92/nogging#<tag>`
- Generated service prefix: `nogg-`

### GitHub metadata

- Description: `Structure for a team of agents: role boundaries, planning and
  Git-evidenced execution for Claude Code, Codex, Pi and Antigravity, built on
  OpenSpec and Beads.`
- Topics (20): `agentic-coding`, `agentic-development`, `ai-agents`,
  `ai-coding`, `beads`, `claude-code`, `cli`, `codex`, `coding-agents`,
  `developer-tools`, `devtools`, `git`, `llm`, `multi-agent`, `openai-codex`,
  `openspec`, `orchestration`, `software-engineering`,
  `spec-driven-development`, `workflow-automation`
- Visibility: public since v3.0.0

_Historical:_ before v3.0.0 the repository was private, carried an earlier
one-line description, and had five topics
(`agentic-development`, `ai-agents`, `beads`, `developer-tools`, `openspec`).
That wording and the private-until-release-readiness decision are superseded.

Nogging is **structure for a team of agents**: it turns autonomous coding
agents into a disciplined team — a Planning Agent, a Lead Agent, and
specialists — each with a defined role, carrying approved intent through
executable work to verifiable Git evidence. It connects OpenSpec intent, Beads
execution state, and Git implementation evidence without replacing those
systems.

## Product and ecosystem name

**Nogging** is the public product name. `Agentsembli SpecForge` is a historical
pre-release identity, not a current qualifier, runtime, package, account,
website, or installation dependency.

## Inspiration and independence

Nogging is conceptually inspired by
[Gas Town](https://github.com/steveyegge/gastown) and its exploration of
multi-agent software development. Nogging is an independent implementation:
it does not include or reuse Gas Town runtime components.

[Beads](https://github.com/gastownhall/beads) is currently the only component
adopted from the Gas Town ecosystem. Nogging is not affiliated with or
endorsed by the Gas Town or Beads maintainers.

## Stability boundary

The first Nogging release establishes the `nogg` command,
installer, configuration, service, and package identifiers. The
unscoped npm package named `nogg` belongs to another project; this project
uses tagged GitHub installation and does not publish to that npm name.

No additional Agentsembli property needs to be claimed for this release. A
future umbrella expansion requires new collision and trademark research,
explicit owner action, and a separately approved migration if technical
identifiers would change.

## Technical identifier inventory

The first public release uses these identifiers as its compatibility surface:

| Surface | Stable identifier |
| --- | --- |
| npm/GitHub package metadata | `nogg` |
| Executable and CLI help | `nogg` |
| Repository-local command | `scripts/nogg` |
| Configuration and state root | `.nogging/` |
| Installed reference documentation | `docs/nogging/` |
| Generated systemd units | `nogg-sync-<slug>` and `nogg-orchestrator-<slug>` |
| Dedicated tmux socket and sessions | `nogg` and `sf-<role>-<bead>-<nonce>` |
| Codex prompt links | `nogg-<prompt>.md` |

Consequently, a clean installation, an update from an earlier Nogging tag,
a rollback to that tag, and removal of the installed tool payload require no
identity migration. OpenSpec content, `.beads/`, project configuration, and
unrelated agent settings remain target-owned data and must not be renamed or
removed as part of those operations.
