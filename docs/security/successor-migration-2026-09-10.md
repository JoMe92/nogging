# Successor repository migration record

Date: 2026-09-10  
Legacy repository: `JoMe92/specforge` (private; never publish)  
Successor repository: `JoMe92/agentsembli-specforge` (private during validation)

This is the redacted operational record for the repository migration. It does
not contain credentials, personal email addresses, raw tracker notes, internal
conversation, or host-specific absolute paths.

## Recovery source

The pre-rewrite recovery set is stored outside both repositories at
`../specforge-private-backups/2026-09-10-pre-public-rewrite/`, relative to the
legacy checkout's parent directory. It contains a bare mirror, an all-refs
bundle with its SHA-256 sidecar, and audit mirrors. Treat the entire directory
as private: it deliberately retains the history excluded from publication.

To restore privately, first verify the bundle with `sha256sum --check` from the
recovery directory, clone the bundle into a new local bare repository, run
`git fsck --full --strict`, and push it only to a newly created **private**
recovery repository. Never push recovery refs into the successor.

## Published seed inventory

Only these refs were seeded into the successor:

Branches:

- `develop`
- `feat/orchestration-agent`
- `feat/pi-agent-support`
- `feat/product-identity`
- `feat/public-release-readiness`
- `fix/ship-claude-payload`
- `main`

Tags:

- `v1.0.0`
- `v1.1.0`
- `v1.1.1`
- `v1.1.2`
- `v1.1.3`
- `v1.2.0`
- `v1.2.1`
- `v1.3.0`
- `v1.4.0`

No pull-request, Dolt, notes, replace, remote-tracking, backup, or other
namespace was pushed. Work for the rename change is added through ordinary
reviewed branch commits after this seed.

## Verification evidence

A fresh mirror clone of the successor advertised 16 refs, all under
`refs/heads/` or `refs/tags/`. The audit found:

- zero legacy pull-request or Dolt refs;
- zero forbidden internal/generated paths;
- zero commit identities outside the configured public GitHub noreply address;
- zero maintainer checkout paths in README history or commit messages;
- zero high-confidence credential signatures; and
- no object-integrity errors from `git fsck --full --strict`.

Run the same fail-closed audit again with:

```bash
scripts/successor-audit.sh JoMe92/agentsembli-specforge
```

The script verifies that the successor is still private before inspecting its
advertised refs and complete reachable history.

## Legacy risk and retirement

The legacy GitHub repository has hidden pull-request refs that retain excluded
pre-cleanup history. GitHub does not allow repository owners to delete those
hidden refs directly. Consequently, the legacy repository must remain private
and must never be used as the public project location.

At cutover the owner must choose one of two safe states: keep the legacy
repository private and archived, or delete it after confirming the private
recovery set. Repository visibility, deletion, and final acceptance remain
manual owner actions.

## Rollback boundary

Before the successor becomes public, rollback may delete the still-private
successor or remove its seeded refs, restore the legacy repository only into a
private destination, and point local remotes back to the legacy URL. After the
successor becomes public, history replacement is no longer an acceptable
rollback: fix forward with new commits, or make the successor private again
before any exceptional repository replacement. A recovery mirror must never be
published.
