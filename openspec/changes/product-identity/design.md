## Context

See `proposal.md` for motivation. The present display and package name is
`SpecForge`; the unscoped npm package is owned by an unrelated hardware
specification project, and web/source searches show other software using the
same phrase. Public-release governance work is therefore paused before writing
canonical metadata.

The point-in-time technical screen on 2026-09-09 produced this shortlist:

| Candidate | Concept fit | npm | PyPI | Exact GitHub repo | GitHub account | `.com` | `.dev` | `.org` | Disposition |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SpecForge | Familiar but generic/colliding | Occupied by unrelated hardware product | Not rechecked | Multiple uses | Existing project account differs | Existing | Existing/unknown | Existing/unknown | Reject as canonical public package identity |
| DeliveryLoom | Weaves intent, work and evidence into delivery | No package observed | No package observed | One exact repository | No exact account observed | No RDAP record | No RDAP record | No RDAP record | Leading candidate; requires mark and live claim checks |
| IntentWeft | Strong concept metaphor but less immediately pronounceable | No package observed | No package observed | No exact repository | Exact account occupied | No RDAP record | No RDAP record | No RDAP record | Backup only because account collision harms consistency |
| PlanLoom | Clear but overemphasizes planning | No package observed | No package observed | No exact repository | Not checked | Registered | No RDAP record | Not checked | Backup; `.com` unavailable |
| TracePact | Suggests traceability and agreement | No package observed | Not checked | One exact repository | Not checked | Registered | No RDAP record | Not checked | Reject unless stronger legal screen supports it |

“No record” means only that the queried registry returned no registration at
the time. It does not reserve the property. `.io` checks were inconclusive and
must be repeated through an authoritative registrar. Formal trademark database
searches and jurisdictional advice remain mandatory owner work.

## Goals / Non-Goals

**Goals:**

- Give the product a crisp, durable concept independent of its eventual name.
- Make selection evidence reproducible and honest about legal uncertainty.
- Prefer one identity that can be claimed consistently across the web, source
  hosting and package ecosystems.
- Perform a tested rename without damaging installed project state or history.

**Non-Goals:**

- Treating DNS, RDAP, GitHub or package lookup results as trademark clearance.
- Buying or registering owner property through an agent.
- Rewriting historical commits to cosmetically replace the old name.
- Renaming before the owner records a selection and proves the minimum claims.

## Decisions

### Define the concept as “intent woven into evidence-backed delivery”

The durable one-line concept is: **A local-first delivery system that carries
approved intent through executable work to verifiable Git evidence.** Its three
pillars remain OpenSpec for intent, Beads for execution state and Git for
implementation evidence. “Loom” candidates fit because they describe joining
those independent threads without claiming to replace any one tool.

Alternatives such as “AI project manager”, “spec generator” and “agent
orchestrator” were rejected because each describes only one surface and would
age poorly as agent integrations change.

### Carry DeliveryLoom as a candidate, not an automatic decision

`DeliveryLoom` currently has the best namespace shape: the three checked core
domains returned no record, npm and PyPI returned no package, and the exact
GitHub account was absent. The existing exact-name GitHub repository and any
unindexed business/mark use still require review. Planning therefore calls it
the leading candidate while keeping the canonical-name field unset.

The owner must decide after checking official trademark databases for intended
markets and performing live registrar/account checks immediately before claim.
If `DeliveryLoom` fails, repeat the same matrix for new candidates instead of
silently falling back to a partially occupied name.

### Claim a minimum identity set before changing the repository

The minimum set is the canonical `.com` domain, one defensive/documentation
domain if desired, GitHub account or organization where applicable, GitHub
repository name, and a scoped npm namespace. Claim order is domains first,
accounts second, repository rename last, minimizing broken links and avoiding
announcing an identity that cannot be secured.

Package publication remains out of scope until public-release distribution
explicitly enables it. Claiming a scope does not authorize publishing.

### Drive all generated identity from a checked-in manifest

Implementation introduces a small human-readable identity manifest containing
the canonical display name, lowercase command/package slugs, repository URL,
homepage, documentation, support/security contacts and legacy aliases. Tests
compare package metadata, CLI help, templates, installed payload and docs with
that manifest. This avoids a brittle blind search-and-replace.

### Preserve a compatibility window

The first renamed release retains an old command shim and recognizes old
configuration/service identifiers long enough to print exact migration steps.
The installer migrates only SpecForge-owned entries and leaves target-owned
OpenSpec/Beads/project content unchanged. The old repository URL should redirect
through GitHub's rename behavior, while the old README and release notes state
the transition explicitly.

## Risks / Trade-offs

- **A “free” name is registered before the owner claims it** → Re-run every
  live lookup immediately before claims and do not publish the shortlist early.
- **A trademark collision is missed** → Require official-jurisdiction searches
  and professional review where commercial exposure warrants it.
- **Renaming breaks scripts or installed services** → Inventory identifiers,
  ship compatibility aliases, and test upgrade/rollback in throwaway repos.
- **Two identities remain visible during transition** → Publish a canonical
  transition page and time-bound deprecation policy.
- **The leading candidate is rejected** → Preserve the concept and scoring
  method; only the label changes.

## Migration Plan

1. Product Owner completes trademark and live availability review, selects the
   canonical name, and claims the required properties manually.
2. Record claim evidence without secrets and commit the identity manifest.
3. Rename internal and user-facing identifiers with compatibility aliases.
4. Update package, repository, docs, templates, workflows and release tooling.
5. Test clean install, upgrade, rollback and uninstall across the rename.
6. Rename GitHub properties manually, configure domains and verify redirects.
7. Publish a transition notice and obtain human acceptance sign-off.

Rollback before step 6 is an ordinary Git revert. After external properties
change, rollback keeps the claims and redirects but restores the prior code
identity until defects are corrected.
