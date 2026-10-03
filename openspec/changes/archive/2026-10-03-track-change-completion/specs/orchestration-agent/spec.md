## ADDED Requirements

### Requirement: The orchestrator directs archiving when doctor reports readiness

When `scripts/specforge doctor` reports a change ready to archive, the
Orchestration Agent SHALL treat that as a signal to direct a planning
session's archive step — either by starting a planning session itself or by
naming the change to one already running — rather than leaving the readiness
note unacted on indefinitely. Directing the archive step this way is
orchestrate-only behavior: the orchestrator still does not perform the
`openspec archive` call itself outside an explicit takeover.

#### Scenario: The orchestrator acts on an archive-readiness note

- **WHEN** the Orchestration Agent reads a `doctor` NOTE reporting a change
  ready to archive
- **THEN** it starts or directs a planning session to perform the archive step
- **AND** it does not call `openspec archive` directly itself outside an
  explicit `/orchestrate takeover plan` instruction
