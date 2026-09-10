## Context

See `proposal.md` for motivation. The old private repository has already had
its normal branches and tags rewritten and its Dolt refs deleted, but GitHub's
immutable `refs/pull/1/head` and `refs/pull/2/head` still expose the pre-cleanup
history. GitHub rejects deletion of those hidden refs. The owner created the
empty private successor `JoMe92/agentsembli-specforge` so publication can start
from the independently verified clean ref set instead.

A complete pre-rewrite mirror and bundle exist outside the repository. The
clean rewrite mirror contains normalized public GitHub noreply identities and
removes internal documents, interaction history, old execution/acceptance
evidence, generated host units, bytecode, and maintainer paths. Repository
visibility, security settings, and acceptance sign-off remain owner-controlled.

## Goals / Non-Goals

**Goals:**

- Populate the new repository from a fresh, scanned source with no legacy PR or
  Dolt refs.
- Apply one identity source consistently across code, documentation, metadata,
  templates, automation, and releases.
- Preserve installed-state compatibility while changing discovery and download
  URLs.
- Make rollback possible until the owner accepts and publishes the successor.

**Non-Goals:**

- Publishing to npm or taking the occupied unscoped npm package.
- Automatically making either repository public.
- Importing old pull requests, issues, Dolt/Beads history, execution logs, or
  GitHub Releases into the successor.
- Renaming the `specforge` command or `.specforge/` state in this release.
- Claiming trademark clearance from availability checks.

## Decisions

### Seed the successor from an allowlisted clean mirror

Push only reviewed heads and tags from the clean rewrite mirror to the empty
successor, then clone the successor independently and scan what GitHub actually
advertises. Do not use GitHub's repository transfer, template, import, or fork
features because they can retain or recreate legacy ref relationships.

Alternative: keep the old repository and ask GitHub Support to delete hidden
refs. Rejected as the primary route because completion and timing are outside
the project owner's control.

### Use an ecosystem-qualified display name but preserve runtime identifiers

Public prose uses **Agentsembli SpecForge**. Repository URLs change to
`JoMe92/agentsembli-specforge`; command, state directory, service prefix, and
installed paths stay `specforge`-based. This gives a distinct public identity
without forcing downstream state migration.

Alternative: rename every technical identifier immediately. Rejected because
it creates unrelated service/configuration migration risk and weakens rollback.

### Replace links from one checked-in identity source

Update `docs/project-identity.md` first, then validate package metadata, CLI
output, README/docs, templates, agent instructions, workflows, security/support
routes, and release text against it. A regression scan allowlists the old URL
only in an explicit transition document and immutable backup instructions.

### Treat old repository retirement as an owner checklist

After successor validation, the owner chooses whether to keep the old repository
private and archived or delete it. It must never be made public while hidden PR
refs retain sensitive history. The checklist records visibility, archive/delete,
default branch, security reporting, issues, topics, release, and remote settings.

### Recreate release evidence instead of copying GitHub metadata

Rewritten tags change object identities and old release metadata may reference
the legacy URL. Create a new candidate tag and release evidence in the successor
after version/link checks; do not present copied historical GitHub Releases as
verified successor releases.

## Risks / Trade-offs

- **Old repository is accidentally exposed** → Keep it private throughout,
  verify visibility before and after cutover, and archive or delete only through
  the owner checklist.
- **A dirty ref reaches the successor** → Push an explicit allowlist, then audit
  a new mirror clone including every advertised ref before any visibility change.
- **Rewritten tags break old checksums** → Treat them as historical/private and
  produce fresh successor release evidence and checksums.
- **Links are only partially renamed** → Add current-surface and package scans
  that fail on unallowlisted `JoMe92/specforge` occurrences.
- **Existing installations lose state** → Test update, rollback, and removal in
  throwaway repositories with sentinel OpenSpec, Beads, config, and agent files.
- **Agentsembli appears to be a separate runtime dependency** → State that
  Agentsembli SpecForge is standalone and Agent Console remains optional.

## Migration Plan

1. Verify the new repository exists, is private and empty; record its immutable
   owner/name and configure private vulnerability reporting before advertising it.
2. Rebuild or revalidate the sanitized mirror from the recorded backup and push
   only explicitly approved branches/tags to the successor.
3. Fresh-clone the successor as a mirror; scan refs, history, identities, paths,
   credentials, package contents and repository visibility.
4. Update identity, package/CLI, documentation, templates and automation; run
   focused and full validation, then commit each mapped Bead normally.
5. Test legacy-tag install → successor update → rollback → uninstall preservation.
6. Create a successor release candidate and unsigned acceptance report; obtain
   owner sign-off in a later commit.
7. Owner archives or deletes the old private repository, updates external GitHub
   settings, and—only after every gate passes—changes successor visibility.

Rollback before public launch: remove successor refs or delete the still-private
successor, restore the old private repository from the verified bundle if needed,
and return local remotes to the recorded legacy URL. Never restore the dirty
backup into a public repository.
