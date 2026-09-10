# Project identity

This document is the canonical identity statement for the first public
SpecForge release.

## Canonical project

- Display name: **SpecForge**
- Repository: <https://github.com/JoMe92/specforge>
- Documentation: the repository `README.md` and `docs/` directory
- Support: <https://github.com/JoMe92/specforge/issues>
- Security reports: GitHub private vulnerability reporting for
  <https://github.com/JoMe92/specforge/security>
- Command and package slug: `specforge`
- Installer entry point: `npx github:JoMe92/specforge#<tag>`
- Generated service prefix: `specforge-`

SpecForge is **a local-first delivery system that carries approved intent
through executable work to verifiable Git evidence**. It connects OpenSpec
intent, Beads execution state, and Git implementation evidence without replacing
those systems.

## Provisional ecosystem name

**Agentsembli is a provisional working name** for a possible wider ecosystem.
It is not a released or required product, registered identity, package, website,
domain, or source-hosting organization. No current SpecForge command, path,
installation, support route, or release depends on Agentsembli.

[Agent Console](https://github.com/JoMe92/agent-console) is an optional sibling
project for orchestration and UI. SpecForge works without Agent Console.

## Inspiration and independence

SpecForge is conceptually inspired by
[Gas Town](https://github.com/steveyegge/gastown) and its exploration of
multi-agent software development. SpecForge is an independent implementation:
it does not include or reuse Gas Town runtime components.

[Beads](https://github.com/gastownhall/beads) is currently the only component
adopted from the Gas Town ecosystem. SpecForge is not affiliated with or
endorsed by the Gas Town or Beads maintainers.

## Stability boundary

The first public release retains the established `specforge` repository,
command, installer, configuration, service, and package identifiers. The
unscoped npm package named `specforge` belongs to another project; this project
uses tagged GitHub installation and does not publish to that npm name.

No Agentsembli property needs to be claimed for this release. A future umbrella
brand requires new collision and trademark research, explicit owner action, and
a separately approved migration if technical identifiers would change.

## Technical identifier inventory

The first public release deliberately keeps the identifiers already used by
installed repositories. They are part of the compatibility surface, not places
where the provisional ecosystem name may be substituted:

| Surface | Stable identifier |
| --- | --- |
| npm/GitHub package metadata | `specforge` |
| Executable and CLI help | `specforge` |
| Repository-local command | `scripts/specforge` |
| Configuration and state root | `.specforge/` |
| Installed reference documentation | `docs/specforge/` |
| Generated systemd units | `specforge-sync-<slug>` and `specforge-orchestrator-<slug>` |
| Dedicated tmux socket and sessions | `specforge` and `sf-<role>-<bead>-<nonce>` |
| Codex prompt links | `specforge-<prompt>.md` |

Consequently, a clean installation, an update from an earlier SpecForge tag,
a rollback to that tag, and removal of the installed tool payload require no
identity migration. OpenSpec content, `.beads/`, project configuration, and
unrelated agent settings remain target-owned data and must not be renamed or
removed as part of those operations.
