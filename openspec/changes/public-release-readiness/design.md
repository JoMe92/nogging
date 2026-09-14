> **Naming update (2026-09-14):** the project has since renamed to **Nogging**
> (see `rename-to-nogging`). The "SpecForge"/"Agentsembli" framing below is the
> historical context this change was written against; treat every reference to
> keeping SpecForge canonical and Agentsembli provisional as superseded by the
> Nogging identity.

## Context

The audit found a healthy functional core and green CI, but no root license or
community/security files, stale and contradictory onboarding, a broad package
allowlist, one old unsigned acceptance report, no automated release workflow,
no compatibility matrix, and public-data risk across Git plus advertised Dolt
refs. The unscoped npm name is owned by another project. See `proposal.md` for
scope and the four delta specs for required outcomes.

## Goals / Non-Goals

**Goals:**

- Turn public readiness into evidence-producing gates rather than a cosmetic
  README pass.
- Make a clean tagged GitHub install the single supported initial distribution.
- Keep legal, privacy, security, documentation, packaging, compatibility, CI,
  and acceptance work independently executable where possible.
- End with a report that leaves only the GitHub visibility toggle to the owner.
- Present Nogging as a credible standalone open-source project (superseding
  the original SpecForge/provisional-Agentsembli framing).

**Non-Goals:**

- Changing repository visibility.
- Publishing to the npm registry or claiming an npm package name.
- Rewriting Git/Dolt history before the audit proves it necessary and the owner
  explicitly approves the destructive migration.
- Promising native Windows, macOS, or unsupported agent compatibility without
  matching evidence.
- Creating a Nogging website, or treating "Nogging" as a finished commercial
  brand beyond GitHub availability (repository rename itself is already done,
  separately, by `rename-to-nogging`).

## Decisions

### Use GitHub-tag installation as the first public distribution

Mark the package private to prevent accidental registry publication while
retaining `npx github:JoMe92/nogging#<tag> init`. This avoids the previously
occupied unscoped npm name and limits this change to an already-tested
channel. A later proposal can introduce a scoped npm package such as
`@jome92/nogg`.

### Preserve ISC unless the owner separately changes the license decision

The existing package metadata already declares ISC, so readiness will add the
matching full license and copyright identity instead of silently changing the
project's legal terms. Third-party material receives an inventory and notices
where required.

### Treat every advertised ref and Dolt record as public data

The audit must inventory Git branches/tags/pull refs, `refs/dolt/data`, the
metadata branch, tracked Beads interactions, reports, and source notes. Clean
items stay; unsuitable items are removed from current refs. Any history rewrite
is a separate owner-approved operation because it invalidates clones, tags, and
release provenance.

### Separate public user docs from maintainer and historical docs

Keep repository history and design evidence available where safe, but package
only an explicit user-document set. The README becomes a routing page with one
short successful journey; detailed concepts remain in architecture/operating
docs. Link and payload tests enforce the boundary.

### Keep the public identity narrow and credit its inspiration precisely

Publish the repository under its established **Nogging** name (see
`rename-to-nogging` for the identity itself). The README must not depend on a
website or sibling product to explain Nogging's value. Refer to the
UI/orchestration repository as the optional **Agent Console** sibling project.

Give Gas Town a visible, direct-link acknowledgement as conceptual inspiration.
State in the same section that Nogging is independently implemented, is not
affiliated with or endorsed by Gas Town's maintainers, and currently adopts only
Beads rather than Gas Town runtime components. This is provenance and scope
documentation, not a claim that the projects are compatible or interchangeable.

### Declare compatibility before expanding it

Start from what the implementation actually needs: Linux-first Bash/Python/Git,
optional systemd/tmux features, Node for installation, and individually
versioned agent CLIs. Test claimed combinations in CI; label everything else
experimental or unsupported. Do not convert absence of evidence into a support
promise.

### Layer the work so exposure happens last

Legal/data audit and packaging precede public-facing documentation; docs and
compatibility precede release automation; all implementation precedes the real
candidate acceptance. The readiness report consumes every result but performs
no visibility mutation.

## Risks / Trade-offs

- **The privacy audit finds data in history or Dolt that cannot simply be deleted** → Stop, record exact refs and exposure, and obtain owner approval for a dedicated history-rewrite/migration plan.
- **ISC is incompatible with an included third-party artifact** → Block the legal task until the artifact is removed, relicensed, or correctly attributed.
- **Supporting too many environments delays publication** → Publish an honest narrow matrix rather than weakening evidence.
- **GitHub-only installation is less discoverable than npm** → Provide excellent pinned-tag instructions now; revisit a scoped package separately.
- **Release checks become expensive** → Keep fast PR checks separate from tagged full acceptance while requiring both before approval.

## Migration Plan

1. Inventory and resolve legal, public-data, and tracked-local-artifact risks.
2. Establish the user documentation and public project policy surface.
3. Harden installer/package contents and compatibility tests.
4. Harden CI and add the release/checklist tooling.
5. Produce a release candidate and run full real-distribution acceptance.
6. Commit the unsigned report; obtain the required human acceptance signature.
7. Generate the final readiness report and owner-only visibility checklist.
8. Stop. The owner changes visibility manually in a separate action.

Rollback is ordinary Git reversion until step 8. If a separately approved
history rewrite becomes necessary, its backup, force-push, tag replacement,
Dolt migration, and collaborator notification procedure must be designed and
approved before execution.
