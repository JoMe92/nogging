## Context

Research documented collisions around SpecForge and proposed umbrella names.
The owner rejected a disruptive rename for the initial public release.
SpecForge is the implemented project, repository, CLI, installer, and docs
identity; Agentsembli is a useful concept label but has unresolved similarity
risk and no claimed properties.

## Goals / Non-Goals

**Goals:**

- Keep SpecForge coherent and independently publishable.
- Record Agentsembli without overstating its maturity or ownership.
- Make Gas Town inspiration, Beads adoption, independence, and non-affiliation
  visible and testable.
- Prevent the abandoned rename plan from blocking public-release work.
- Preserve research for a later branding decision.

**Non-Goals:**

- Renaming repositories, packages, commands, services, or installed paths.
- Registering domains, accounts, package scopes, or trademarks.
- Launching an Agentsembli website or commercial product.
- Changing visibility, publishing to npm, or modifying Agent Console.

## Decisions

### Keep SpecForge canonical

Rename cost and risk outweigh discoverability benefit now. GitHub-only
distribution uses the owner-qualified repository URL, and private package
metadata prevents confusion with the occupied unscoped npm name.

### Treat Agentsembli as optional ecosystem language

Every current use calls Agentsembli provisional. No runtime behavior,
installation step, URL, or support path depends on it. SpecForge is the workflow
core and Agent Console an optional UI/orchestration sibling.

### Use a small identity document

`docs/project-identity.md` records current facts and provenance. A focused test
checks public entry points for required names, links, qualification, and stable
identifiers. No generated identity abstraction is needed because nothing is
renamed.

### Keep provenance statements together

Gas Town inspiration appears beside the boundary: only Beads is currently
adopted; no Gas Town runtime component is included; SpecForge is independent
and unaffiliated.

### Defer claims and migration

Research is historical evidence, not an instruction to claim Agentsembli. A
future owner decision starts with fresh research and a new change. No shim,
redirect, cutover, or old-to-new release is needed now.

## Risks / Trade-offs

- **SpecForge is less globally distinctive** → Use qualified GitHub URLs and
  disclose that the unscoped npm package is unrelated.
- **Agentsembli may appear finalized** → Require a provisional qualifier.
- **Attribution may imply inheritance** → Keep independence and Beads-only
  adoption in the same section.
- **A later rename costs work** → Plan it only after a reviewed, claimed name.

## Migration Plan

1. Record the owner decision and identity document.
2. Verify identifiers remain SpecForge-based.
3. Apply identity and provenance language through public-readiness docs.
4. Include identity checks in release-candidate acceptance.

Rollback removes ecosystem wording while leaving SpecForge unchanged.
