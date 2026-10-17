## ADDED Requirements

### Requirement: The README leads a newcomer from purpose to daily use before reference material

`README.md` SHALL present, in this order:

1. a statement of what Nogging is, in no more than three sentences, before
   any section heading;
2. a Quick Guide of at most eight numbered steps that goes from no
   installation to a closed first task, each step carrying a copyable
   command;
3. installation, first for a fresh machine through the pinned
   `scripts/bootstrap`, then for an existing repository through the pinned
   `npx … init`;
4. day-to-day use, covering, in order, planning a change, launching a Lead
   Agent, watching and steering sessions, and closing work out.

Safety, project status, supported environments, concepts, architecture, the
documentation index, maintainer development and provenance SHALL follow day-to-day use or
be linked to `docs/`. The README SHALL keep the rule that install commands
are pinned to a released tag and never to `main` or `develop`. It SHALL
link the security and threat model before any command that grants full
access.

#### Scenario: A newcomer reads the README top to bottom

- **WHEN** a newcomer reads `README.md` from the top
- **THEN** they meet the purpose, the Quick Guide, installation and day-to-day use before any concept, architecture or maintainer section
- **AND** they can install, check readiness, plan a change and launch a Lead by copying commands from the Quick Guide

#### Scenario: The order is checked mechanically

- **WHEN** the README structure test runs
- **THEN** it fails if a required section is missing or out of order, if the intro exceeds three sentences, if the Quick Guide exceeds eight steps, or if an install URL is not pinned to a released tag

#### Scenario: Full access is reached only after the safety link

- **WHEN** the README first shows a `session launch` command with `--full-access`
- **THEN** a link to the security and threat model appears earlier in the README
