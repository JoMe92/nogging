## Why

The owner has developed a full brand concept for **Nogging** — "the structural
layer for agentic software development" — and needs to move off **Agentsembli
SpecForge** because of a name collision. Unlike the 2026-09-10 rename, the
GitHub repository has never gone public, so there is no external installation
depending on the current `specforge` command, `.specforge/` state root, or
`SpecForge-Writer` commit convention. This is a clean window to rename the
technical identifiers alongside the display name, not just the display name.

## What Changes

- **BREAKING**: Rename the canonical repository from
  `JoMe92/agentsembli-specforge` to `JoMe92/nogging` via GitHub's native rename
  (history and redirect preserved); update description/topics.
- Adopt **Nogging** as the full identity — display name and technical
  identifiers: CLI command `nogg`, npm package name `nogg`, state root
  `.nogging/`, commit trailer `Nogging-Writer` / env var `NOGGING_WRITER`,
  entry script `scripts/nogg`, systemd unit prefix `nogg-*` (including the
  orchestrator singleton `nogg-orchestrator-<slug>`).
- Migrate this delivery machine's already-live installation (the running
  `specforge-sync.timer`/`.service` and the state under
  `.specforge/state/worktrees/`) to the new names as an explicit, verified
  step — not a silent rename.
- Publish a full, brand-appropriate README using the three supplied Nogging
  logo/banner assets (hero banner, tagline, quick start under the `nogg`
  command).
- Add the governance/community files that TASK-PUB-004 (`SPEC-xdnw`) left
  blocked pending exactly this naming decision: `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, a refreshed `SECURITY.md` route, issue forms, a
  pull-request template, and documented GitHub description/topics — without
  changing repository visibility.
- Archive the completed-but-unarchived `rename-agentsembli-specforge` change
  first, so the OpenSpec `product-identity` baseline sequences correctly
  before this change's own identity work lands.

## Non-Goals (explicit, owner-approved)

- **Not** rewriting the ~17 existing OpenSpec capability specs (`installer`,
  `claude-sessions`, `codex-onboarding`, `pi-onboarding`, `beads-sync`,
  `sync-safety`, `write-boundary`, `tool-agnostic-write-boundary`,
  `branch-discipline`, `run-recovery`, `run-hygiene`, `specialist-agents`,
  `orchestration-agent`, `launch-profiles`, `workflow-commands`,
  `agent-neutral-launch`, `acceptance`) that still hardcode `specforge`
  identifiers in their requirement text. That divergence is accepted and
  documented, not an oversight.
- **Not** migrating the Beads issue-ID prefix (`SPEC-` stays).
- **Not** changing repository visibility, publishing to npm, or claiming
  trademark clearance for "Nogging"/"nogg" — those remain separate human
  decisions, same caveat as the prior two naming rounds.
- **Not** resuming the still-blocked Git/Dolt public-history sanitization
  (`SPEC-c4o5`) — unrelated, tracked separately for whenever public release
  resumes.

## Capabilities

### Modified Capabilities

- `product-identity`: replaces the (unarchived) Agentsembli SpecForge identity
  with the Nogging identity — display name, renamed technical identifiers,
  legacy-name provenance chain, the accepted spec-text divergence, and the
  README/brand presentation bar.

## Impact

Affected surfaces: GitHub repository name/description/topics; `package.json`
(`name`, `bin`) and `bin/cli.js`/`bin/lib/*`; `.specforge/` → `.nogging/`
state root (including this machine's existing local state);
`scripts/specforge` → `scripts/nogg` and its test files;
`SpecForge-Writer`/`SPECFORGE_WRITER` across git hooks, scripts, and tests
(112 occurrences); systemd templates and this machine's live sync unit;
`.claude/`, `.codex/`, `.pi/` agent configs; README and new brand assets;
`CONTRIBUTING.md`/`CODE_OF_CONDUCT.md`/`SECURITY.md`/issue and PR templates;
`docs/*` prose; `.github/workflows/specforge-validate.yml`. **Not affected**:
the wording of the 17 existing OpenSpec capability specs, and the Beads
`SPEC-` issue prefix.
