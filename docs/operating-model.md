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

Agents record every material discovery on their active Bead using the native
Beads `discovery` label plus a required human-readable note:

```bash
bd update <id> --add-label discovery --append-notes "<prose summary>"
```

Execution agents never edit `openspec/`, so every discovery waits for the next
planning session (`bd list --label discovery`) and does not alter an approved
OpenSpec change automatically.

A discovery is **non-blocking** when the claimed task still finishes as
specified; the agent keeps working. It is **blocking** when the task cannot be
finished sensibly as specified; the agent also runs `--status blocked` and
moves to the next independent Bead. `/discovery-review` lists blocked
discoveries first so they do not get lost.
