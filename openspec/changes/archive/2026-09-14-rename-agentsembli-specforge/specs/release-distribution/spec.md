## Purpose

Defines how the sanitized project history is transferred and released from the
new GitHub-only repository without carrying private legacy refs or artifacts.

## ADDED Requirements

### Requirement: The new repository starts from the sanitized history

The canonical repository SHALL receive only the verified rewritten branches and
tags. It SHALL NOT receive legacy pull refs, Dolt refs, `.beads/interactions.jsonl`,
internal source notes, old acceptance history, generated host units, bytecode,
maintainer-local paths, credential material, or private/local commit identities.

#### Scenario: Clean repository is populated

- **WHEN** the sanitized mirror is pushed to the newly created private repository
- **THEN** a fresh mirror clone exposes only approved heads and tags and every privacy and forbidden-artifact scan passes

### Requirement: GitHub-only distribution uses the new repository

The package SHALL remain blocked from npm-registry publication. Installation,
update, rollback, changelog, checksums, release notes, and post-release smoke
tests SHALL use an exact tag from `JoMe92/agentsembli-specforge`.

#### Scenario: Tagged installation succeeds

- **WHEN** a user runs the documented `npx github:JoMe92/agentsembli-specforge#<tag>` command
- **THEN** the expected CLI and payload install successfully without contacting the npm registry for this package

### Requirement: A recoverable private backup precedes cutover

Before destructive replacement, a complete private mirror and verified bundle
of the legacy repository SHALL exist with a checksum and restoration notes.
The backup SHALL remain outside both public Git history and package contents.

#### Scenario: Cutover must be rolled back

- **WHEN** validation fails before public visibility changes
- **THEN** the owner can restore the legacy private repository from the recorded backup without losing its original refs
