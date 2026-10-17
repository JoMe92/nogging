## MODIFIED Requirements

### Requirement: The public README presents the Nogging brand and is complete

`README.md` SHALL present the Nogging identity using the supplied brand
assets: a banner image at the top, the validation badge, and the tagline
"Structure for a team of agents.". It SHALL cover: purpose, a Quick Guide,
install instructions, day-to-day use, the two-phase planning/execution
model, the non-negotiable-boundaries table, and how to run the tests
(`scripts/test`). The CI job reference SHALL be in `CONTRIBUTING.md`, linked
from the README. Every internal link and every in-repository anchor SHALL
resolve.

#### Scenario: A new visitor reads the README

- **WHEN** a visitor opens `README.md` on the renamed repository
- **THEN** the banner, the badge and the tagline appear before the first section
- **AND** every documented command uses the `nogg` CLI, matching what is
  actually installed

#### Scenario: A README link or anchor is followed

- **WHEN** any relative link in `README.md` is followed, including a `#fragment` into the README or into a file under `docs/`
- **THEN** the target file exists
- **AND** the fragment matches a heading slug in that file
