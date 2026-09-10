## Why

The owner has selected **Agentsembli SpecForge** and created the private target
repository `https://github.com/JoMe92/agentsembli-specforge`. Moving the public
release to that clean repository avoids GitHub's undeletable legacy pull refs
while giving the project a distinctive ecosystem-qualified identity.

## What Changes

- **BREAKING**: Make `JoMe92/agentsembli-specforge` the canonical repository and
  GitHub-tag installation source; retire the old `JoMe92/specforge` repository
  from distribution after preservation and redirect/archive handling.
- Adopt **Agentsembli SpecForge** as the public display name while retaining
  `SpecForge` as the component name and historical provenance.
- Keep the `specforge` CLI, `.specforge/` state root, installed paths, and
  generated service prefixes compatible for the first renamed release.
- Publish only the already sanitized Git history: no legacy pull refs, Dolt
  refs, interaction export, internal source notes, old acceptance history,
  generated host units, bytecode, private paths, credentials, or private/local
  commit identities.
- Update package metadata, documentation, support/security routes, templates,
  release automation, installation examples, and acceptance evidence to the
  new repository.
- Provide an exact owner-run cutover, rollback, and old-repository retirement
  checklist. While private, `SECURITY.md` supplies the reporting instructions;
  the owner enables and verifies GitHub Private Vulnerability Reporting
  immediately after making the repository public. Visibility and final
  acceptance remain human actions.

## Capabilities

### New Capabilities

- `product-identity`: Defines the Agentsembli SpecForge identity, repository
  cutover, compatibility boundary, provenance, and owner-controlled launch.
- `release-distribution`: Defines clean-history transfer and release evidence
  for the new GitHub-only repository.

### Modified Capabilities

- `installer`: Changes the canonical tagged GitHub source while preserving
  existing installed state and the `specforge` command compatibility surface.
- `acceptance`: Requires clean-clone, upgrade, rollback, link, history, and
  supported-agent evidence against the new repository before publication.

## Impact

Affected surfaces include GitHub repository/remotes, tags and releases;
`package.json`; the CLI help and installer source; README and maintained docs;
agent templates/prompts; security/support routes; release and acceptance
automation; and every test that asserts the canonical repository identity.
The old private backup remains offline and must never be pushed to the new
repository. npm publication and automatic visibility changes remain out of
scope.
