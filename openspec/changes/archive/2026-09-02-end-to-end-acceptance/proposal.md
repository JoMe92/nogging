# Validate the whole SpecForge toolkit end to end

## Why

SpecForge has been built one capability at a time: the installer
(`specforge-installer`), the mechanical sync fixes (`reliable-beads-sync`),
remote session supervision (`remote-observable-claude-sessions`), branch
discipline (`enforce-conventional-branching`), the workflow slash commands
(`planning-and-discovery-commands`) and the specialist agent roster
(`specialist-agents-and-skills`). Each change has its own validation, but
nothing exercises the full chain — install into a fresh repository, plan,
materialize, execute with delegation, sync, review discoveries, accept — in one
run, and nothing produces a record a human can sign off.

The concept conversation of 2026-08-31 (`docs/source/konversation-export.md`,
section 12) sketched exactly this run as a narrative ("Foto-Import vom
Dateisystem") but only as prose. There is no procedure to reproduce it, no
harness for the parts that need no agent, and no acceptance artefact.

## What changes

- **A reproducible acceptance runbook** (`docs/acceptance.md`): the full ordered
  procedure from an empty git repository to a signed-off run, with every step
  marked as either *mechanical* (no LLM, scriptable) or *agent-driven* (guided,
  manual), its prerequisites, and its expected observable outcome.
- **A mechanical acceptance harness** (`scripts/acceptance.sh`): spins up a
  throwaway repository, installs SpecForge, asserts the readiness verdict
  reports ready, opens a planning session, drops in a canned example change,
  validates, materializes Beads, mirrors a closed Bead through sync, asserts
  sync idempotency and a `doctor`/`audit` clean, and tears down. A
  `--mechanical` subset runs with no Beads backend by stubbing `bd`.
- **A canned example change** under `scripts/fixtures/acceptance/` — a minimal
  two-task change that stands in for the section 12 example without shipping a
  real feature.
- **An acceptance report template** (`docs/acceptance-report-template.md`):
  per-step pass/fail, deviations, open discoveries, and a Product Owner
  sign-off line. Completed reports are stored under `docs/acceptance/`.
- **A CI job** running the mechanical subset on every push and pull request so
  a regression anywhere in the chain fails the build.

## Capabilities

### New Capabilities

- `acceptance`: a reproducible end-to-end procedure that validates the whole
  SpecForge toolkit against a fresh target repository, records the run in a
  dated report with a human sign-off, and runs its no-LLM subset unattended in
  CI.

### Modified Capabilities

<!-- none -->

## Impact

- New files: `docs/acceptance.md`, `docs/acceptance-report-template.md`,
  `scripts/acceptance.sh`, `scripts/acceptance.test.sh`,
  `scripts/fixtures/acceptance/**`, `docs/acceptance/` (report store).
- Modified: `.github/workflows/specforge-validate.yml` (new `acceptance` job),
  `docs/operating-model.md` and `README.md` (point to the procedure).
- Depends on every other roadmap change being implemented; `specforge-installer`
  is already implemented, the rest are planned.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
