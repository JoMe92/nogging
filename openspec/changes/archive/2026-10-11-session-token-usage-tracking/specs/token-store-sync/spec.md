## Purpose

Keep usage facts queryable locally and safely merge independent device histories without coupling telemetry to Beads or source Git.

## ADDED Requirements

### Requirement: Independent durable queryable storage

The system SHALL own a versioned usage database independent of Beads schema and source Git, shared across linked worktrees on one host. Stable shared project identity, distinct device identities and global source-event identities SHALL support concurrent device histories and copied-source deduplication. Local persistence SHALL work without a remote or new persistent service. Init/update/remove SHALL preserve user-owned usage data and unrelated configuration.

#### Scenario: Multiple worktrees
- **WHEN** two linked worktrees collect the same runtime event
- **THEN** they address the canonical local store and contribute one effective fact

#### Scenario: Independent devices and copied sources
- **WHEN** two store clones with distinct device UUIDs write offline and one imports a source already collected by the other
- **THEN** independent facts remain distinct while the copied fact is counted once

#### Scenario: Payload update and removal
- **WHEN** the installed tool payload is updated or removed
- **THEN** database, pending facts and identity survive and unrelated hooks/configuration are preserved

### Requirement: Explicit conflict-safe multi-device synchronization

`nogg token-usage sync` SHALL explicitly synchronize an independently configured usage remote using supported fetch/merge/push semantics, preserving local offline writes. Remote operations SHALL require trusted operator/orchestrator authority; restricted collection SHALL remain local. Init/collect/report and the Beads multi_machine setting MUST NOT silently enable usage network sync. Synchronization SHALL serialize against local ingestion, bound rejected-push retries and retain local facts on network failure. Reports SHALL expose last successful synchronization.

#### Scenario: Offline concurrent inserts
- **WHEN** two devices independently collect usage offline and synchronize in either order
- **THEN** their nonconflicting facts converge and model/task/complexity reports include both without lost or duplicate counts

#### Scenario: Rejected push or outage
- **WHEN** another device updates the remote during a push or the network is unavailable
- **THEN** bounded retries or pending status preserve all local facts and do not prevent local collection or task completion

#### Scenario: Restricted caller
- **WHEN** a restricted session requests remote synchronization
- **THEN** it is refused without granting remote authority, while its local usage remains collectible

### Requirement: Schema and identity conflicts fail visibly

Conflicting contents for the same fact revision, competing source ownership or incompatible schema versions SHALL stop synchronization with retained local data and actionable diagnostics. The system MUST NOT force push, silently discard one side or apply blanket ours/theirs conflict resolution. Newer unsupported schema SHALL refuse mutation.

#### Scenario: Identity collision
- **WHEN** two devices produce different contents for the same canonical fact revision
- **THEN** sync reports the conflict and retains both recoverable histories without silently selecting a winner

#### Scenario: Newer remote schema
- **WHEN** a remote uses a schema the installed collector cannot read safely
- **THEN** synchronization refuses before accepting incompatible data and local recoverable facts remain intact
