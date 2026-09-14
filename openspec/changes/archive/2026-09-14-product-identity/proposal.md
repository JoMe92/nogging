> **Superseded (2026-09-14):** the project has since renamed to **Nogging**
> (see `rename-to-nogging`), which also redefines the `product-identity`
> capability. This change's capability claim was already folded into the
> OpenSpec baseline by `rename-agentsembli-specforge`'s archive, and its four
> remaining tasks (TASK-IDENT-005 through 008) are closed as superseded. Kept
> here as historical record of the "keep SpecForge, Agentsembli provisional"
> decision that predated the rename.

## Why

SpecForge needs a clear public identity before its documentation and release
metadata are finalized. A forced rename would add migration and ownership work
without improving the first public release. The owner has therefore chosen to
keep **SpecForge** as the standalone public project name and use
**Agentsembli** only as a provisional working name for a possible ecosystem.

## What Changes

- Record SpecForge as the canonical public project name for this release.
- Define Agentsembli as a provisional ecosystem working name, not a required
  product, package, domain, organization, or website.
- Keep existing repository, command, installer, service, and package identifiers
  stable; no rename or compatibility migration is introduced.
- Add a concise, checked-in identity and provenance statement.
- Credit Gas Town as conceptual inspiration while stating that SpecForge is an
  independent implementation, currently adopts only Beads from that ecosystem,
  and is not affiliated with or endorsed by Gas Town's maintainers.
- Describe Agent Console as an optional sibling rather than a dependency.
- Preserve prior collision research and defer future commercial umbrella-brand
  work without blocking this release.

## Capabilities

### New Capabilities

- `product-identity`: Defines the stable SpecForge identity, provisional
  Agentsembli language, provenance, and no-rename boundary.

### Modified Capabilities

None. Public-release readiness consumes this decision and owns the actual
README, governance, distribution, and acceptance work.

## Impact

The change affects identity documentation, public wording, validation, and
acceptance evidence. It does not rename technical identifiers; claim external
properties; publish to npm; create a website; change visibility; or modify
Agent Console.
