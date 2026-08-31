# Operating model

## Roles

- **Product Owner:** describes desired outcomes, decides ambiguities, accepts and archives changes.
- **Planning Agent:** works only in a deliberate planning session; writes OpenSpec and creates/reconciles Beads.
- **Main Worker:** selects `bd ready`, delegates isolated implementation work, validates, commits, records evidence and closes Beads.
- **Specialists:** work only on a claimed Bead and report results to the Main Worker.
- **Sync timer:** polls every 30 seconds and mirrors facts only.

## Branches and commits

`main` is the stable integration branch. `develop` is the active integration
branch. Use Conventional Branches: `feat/<change-id>`, `fix/<change-id>`,
`chore/<topic>`. Use Conventional Commits, for example
`feat(import): add filesystem picker [SPEC-abc123]`.

Planning changes are committed on their change branch and merged into `develop`
after `./scripts/specforge validate`. The timer makes local commits only when
there is a tracked execution-log update; it never pushes.

## Discoveries

Agents record every material discovery in their active Bead. There are only two
kinds:

- `automatic`: a narrow, backwards-compatible implementation detail.
- `review`: anything user-visible, architectural, ambiguous, security or performance relevant.

`review` discoveries go to the next planning session. They do not alter an
approved OpenSpec change automatically. Add `"blocking": true` only when safe
execution cannot continue.
