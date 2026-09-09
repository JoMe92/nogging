## Why

The current name, SpecForge, is already used by an unrelated npm package and
other software projects, making a public launch confusing and preventing this
project from claiming its obvious unscoped package identity. The product also
needs a concise concept statement and a defensible naming decision before
public documentation, accounts, domains, and release artifacts are finalized.

## What Changes

- Define the product concept as a local-first delivery system that carries
  approved intent through executable work to verifiable Git evidence.
- Establish objective name criteria: distinctive, pronounceable, tool-neutral,
  internationally usable, available across required namespaces, and not
  misleading about vendor affiliation.
- Record a dated, reproducible collision and availability review for the
  current name and shortlisted candidates.
- Make formal trademark review and claiming domains/accounts explicit manual
  owner gates; availability observations alone do not authorize registration
  or establish trademark clearance.
- Select a canonical product name only after those gates pass.
- **BREAKING**: Once selected and claimed, rename user-facing identity,
  repository/package metadata, CLI output, installed paths and documentation
  through a compatibility-controlled migration.
- Preserve historical provenance and publish an old-to-new-name transition
  notice rather than silently rewriting project history.

## Capabilities

### New Capabilities

- `product-identity`: Defines the concept, naming evidence, owner-controlled
  claim gates, canonical identity, and compatibility requirements for a public
  product rename.

### Modified Capabilities

None. The public-release-readiness change remains independently planned and is
blocked from final public metadata until this identity decision is complete.

## Impact

The decision can affect the GitHub repository and organization, domains, npm
and other package namespaces, package name and metadata, CLI name and output,
installed files and service names, documentation, badges, links, release tags,
security contacts, and downstream installation commands. No domain, account,
package, trademark, or repository rename is performed during planning.
