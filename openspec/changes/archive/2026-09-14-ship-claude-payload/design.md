## Context

The repository already owns six Claude specialist definitions and four Claude
workflow commands. `mergeClaudeSettings()` separately preserves and augments
consumer-owned `.claude/settings.json`, while the install manifest has no entry
for either payload directory. The `package.json` allowlist also omits `.claude`,
so a GitHub-backed npm pack cannot make those source files available to the
installer.

## Goals / Non-Goals

**Goals:**

- Treat Claude agent and command definitions as released, verbatim tool files.
- Keep local-checkout and packed `npx github:` installs behaviorally identical.
- Prove fresh install, update refresh, package inclusion, and idempotence.

**Non-Goals:**

- Merging consumer modifications inside managed agent or command definitions.
- Changing `.claude/settings.json` merge behavior or the contents of the
  existing Claude definitions.
- Automatically updating already installed consumer repositories as part of
  this repository change.

## Decisions

### Copy the two narrow subdirectories verbatim

Add `.claude/agents` and `.claude/commands` as separate `verbatimDirs` entries,
rather than copying all of `.claude`. This matches the existing Codex and Pi
payload model while leaving `.claude/settings.json` under its idempotent merge
strategy and `.claude/settings.local.json` entirely target-owned.

Alternative considered: copy the entire `.claude` directory. Rejected because
that would overwrite settings and local state that the installer explicitly
promises to preserve.

### Include matching narrow paths in the package allowlist

Add `.claude/agents` and `.claude/commands` to `package.json#files`. Listing the
same source roots in both package and install manifests makes the distribution
boundary explicit and mirrors `.codex/prompts` and `.pi/prompts`.

Alternative considered: include all of `.claude`. Rejected for the same
ownership reason and because `settings.local.json` must not ship.

### Extend the focused installer test

Assert representative and complete file-set equality for fresh installs, then
exercise a stale target file through `update`. Extend the existing packed
install section to prove the payload survives npm's files filtering. The
existing re-init tracked-diff test remains the idempotence backstop.

## Risks / Trade-offs

- **Consumer edits to managed definitions are overwritten on update** → Document
  and test them as verbatim released payloads; customization belongs outside
  these SpecForge-owned paths.
- **A future Claude payload directory could be forgotten** → Keep explicit,
  narrow allowlists and tests for both currently supported directories.
