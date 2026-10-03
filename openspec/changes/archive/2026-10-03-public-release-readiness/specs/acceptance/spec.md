## ADDED Requirements

### Requirement: Public release candidates receive current real-distribution acceptance

Before public-release readiness is approved, the acceptance procedure SHALL run
against the exact candidate tag from a clean repository and SHALL cover a real
GitHub installation, update from the preceding supported release, rollback,
uninstall preservation, hook behavior with Beads, recovery, and the supported
Claude Code, Codex, and Pi paths. Any unavailable optional path SHALL be marked
with an explicit unsupported or deferred product decision rather than silently
skipped.

#### Scenario: A release candidate is accepted

- **WHEN** the public release-candidate run completes
- **THEN** the dated report identifies the exact tag and commit and records evidence for install, update, rollback, removal, recovery, hooks, and every supported agent path
- **AND** every deviation has a Bead ID or an explicit accepted limitation

### Requirement: Public-release acceptance requires human sign-off

The final release-candidate report SHALL be committed with an empty sign-off
and SHALL require a later human commit to complete it. Automated CI, an agent,
or closure of all implementation Beads SHALL NOT substitute for this sign-off.

#### Scenario: Automation completes all mechanical checks

- **WHEN** every automated release-candidate check passes but the report is unsigned
- **THEN** public-release readiness remains unapproved
- **AND** repository visibility remains unchanged
