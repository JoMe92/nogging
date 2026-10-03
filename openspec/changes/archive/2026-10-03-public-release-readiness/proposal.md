> **Naming update (2026-09-14):** the project has since renamed to **Nogging**
> (see `rename-to-nogging`). Every "SpecForge"/"Agentsembli" reference below is
> historical context for why this change exists; the readiness work itself
> stays valid and should target the Nogging identity going forward.
> `TASK-PUB-004` closed as implemented via `TASK-NOG-011`; `TASK-PUB-005` and
> `TASK-PUB-015` were updated in `tasks.md` to target Nogging.

## Why

SpecForge is functional and released privately, but its repository, installer,
documentation, security posture, and release evidence do not yet form a safe,
clear public product. Before the owner makes the repository public, every
machine-verifiable readiness gap should be closed and the remaining manual
decision should be reduced to one explicit visibility-change checklist.

## What Changes

- Establish public-project governance: an actual ISC license, contribution and
  conduct guidance, a security policy, support expectations, project metadata,
  and third-party attribution.
- Audit Git history, Beads/Dolt refs, tracked operational state, reports, and
  source notes for secrets or private information; remove or sanitize anything
  unsuitable for publication before history becomes public.
- Replace the maintainer-oriented README with a user-first introduction,
  five-minute walkthrough, support matrix, safety model, and links to task-based
  documentation.
- ~~Keep SpecForge as the public project name and describe Agentsembli only as
  the provisional working name~~ — superseded by `rename-to-nogging`: the
  project is now **Nogging**, and public-facing text should say so.
- Credit Gas Town as a conceptual inspiration, state that Nogging is an
  independent implementation, and identify Beads as the only Gas Town component
  currently adopted rather than implying code reuse or affiliation.
- Reconcile installation and operating documentation with current behavior,
  including Beads initialization, Claude/Pi/Codex payloads, version pinning,
  hooks, systemd, update, rollback, and uninstall.
- Harden the GitHub-only distribution: declare that npm registry publication is
  out of scope, prevent accidental npm publication, constrain the package
  allowlist, and prove clean/tagged packages contain no generated or internal
  artifacts.
- Define and test the supported runtime/platform matrix, harden GitHub Actions,
  add dependency and security automation, and make release artifacts
  reproducible and verifiable.
- Add a public release process with a changelog, signed or otherwise verified
  tags, checksums/SBOM where supported, and a tagged-install smoke test.
- Run and sign a current release-candidate acceptance report covering the real
  distribution and supported agent paths.
- Produce a final readiness report and manual owner checklist.
- **EXCLUDED MANUAL ACTION:** changing the GitHub repository visibility to
  Public remains an owner-only action after every gate passes; no task or agent
  automation may perform it.

## Capabilities

### New Capabilities

- `public-project-readiness`: Defines the legal, privacy, documentation,
  governance, security, and final approval gates required before publication.
- `release-distribution`: Defines a clean GitHub-based package and repeatable,
  verifiable public release process.

### Modified Capabilities

- `installer`: Make the public installation, update, rollback, uninstall,
  platform support, and delivered-documentation behavior complete and
  accurately discoverable.
- `acceptance`: Require release-candidate evidence for the real tagged
  distribution and each supported agent path before public-release approval.

## Impact

The change affects repository metadata and community files, README and user
documentation, npm package metadata/allowlisting, installer behavior and tests,
GitHub workflows, release tooling, acceptance procedures and reports, tracked
operational artifacts, and potentially public Git/Dolt history. It documents
Agent Console as an optional sibling project without changing that repository.
It does not launch a Nogging website, publish to npm, or change repository
visibility. (It previously also excluded renaming the project; `rename-to-nogging`
has since done that separately.)
