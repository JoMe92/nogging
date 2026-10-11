## ADDED Requirements

### Requirement: Change-associated follow-ups are distinct from mapped tasks

A Bead with openspec:followup and exactly one openspec:change label but no openspec:task label SHALL be a valid non-task follow-up. It SHALL retain change traceability, SHALL NOT satisfy or generate a task checkbox, and SHALL block mapped work only through explicit dependencies. Malformed mappings SHALL remain actionable diagnostics and SHALL NOT be automatically deleted or relabeled.

#### Scenario: Legitimate follow-up

- **WHEN** a labeled non-task follow-up exists for a change
- **THEN** audit accepts its association and sync does not invent a task

#### Scenario: Invalid follow-up mapping

- **WHEN** a follow-up also carries a task label
- **THEN** audit rejects the ambiguous representation and names the Bead

### Requirement: Mapping failures are isolated to identifiable affected changes

Materialize for a target change SHALL refuse only target-affecting or repository-wide ambiguous invariants. Sync SHALL quarantine identifiable affected changes and reconcile unaffected valid changes idempotently. Strict validate/audit SHALL still report all defects nonzero. Unreadable tracker state and genuinely unscopable identity conflicts SHALL fail closed repository-wide.

#### Scenario: Unrelated malformed label pair

- **WHEN** change A has a malformed associated Bead and change B is valid
- **THEN** materialize and sync can process B while naming and skipping A

#### Scenario: Global identity ambiguity

- **WHEN** the system cannot determine unique task ownership
- **THEN** no reconciliation write occurs
