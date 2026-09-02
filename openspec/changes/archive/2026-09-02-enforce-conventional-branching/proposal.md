# Enforce branch and commit discipline in CI

## Why

The concept conversation of 2026-08-31 (`docs/source/konversation-export.md`,
section 4) asked for a CI invariant that rejects any change not traceable to a
Bead. Today nothing enforces this:

- `docs/operating-model.md` documents Conventional Branches loosely
  (`feat/<change-id>`), but no check verifies a branch name. Branches drift to
  ad hoc names and a reviewer cannot tell from the branch which OpenSpec change
  a pull request advances.
- `scripts/hooks/commit-msg` enforces a Conventional Commit subject **and** a
  real Beads issue ID token, with an exemption for planning and sync writers.
  But this repository sets `core.hooksPath` to `.beads/hooks`, so that hook
  never runs locally here — a limitation already recorded in
  `docs/architecture.md`. The only backstop,
  `.github/workflows/specforge-validate.yml`, validates OpenSpec structure and
  runs the script tests; it never inspects a pull request's branch name or its
  commit subjects. A commit with no Bead reference merges cleanly.
- The `commit-msg` writer exemption keys off the `SPECFORGE_WRITER` environment
  variable, which is invisible to anything reading a pushed commit. CI cannot
  reproduce the exemption. The repository's own planning commits use a `plan:`
  subject that is not a Conventional Commit type at all; they pass only because
  the local hook is bypassed.

## What changes

- **A branch-naming convention that is written down and checked.** A working
  branch is named `<type>/<slug>`, where `<type>` is a Conventional Commit type
  or `plan`. A branch that advances an OpenSpec change SHALL use that change's
  `openspec/changes/<slug>/` directory name as its `<slug>`. `chore/<topic>`
  and `plan/<topic>` cover work not scoped to one change. `main` and `develop`
  are protected and exempt.
- **A portable writer marker.** Planning and sync commits carry a
  `SpecForge-Writer: planning` or `SpecForge-Writer: sync` trailer in the
  commit message, not only an environment variable. The `commit-msg` hook
  honours the trailer in addition to the env var; CI reads the same trailer.
  The non-Conventional `plan:` subject prefix is retired.
- **A CI invariant job.** On `pull_request`, a new job checks the head branch
  name against the convention and re-runs the `commit-msg` rule over every
  non-merge commit the pull request introduces, honouring the trailer
  exemption. It fails with a message naming the offending branch or the
  offending commit by SHA and subject.
- **A local `pre-push` hook.** Installed by `scripts/install-hooks`, it gives
  the branch-name feedback before a push where `.git/hooks` is active. CI stays
  authoritative where `core.hooksPath` is diverted.

## Impact

- Affected specs: `branch-discipline` (new capability).
- Affected code (implementation deferred to execution):
  `.github/workflows/specforge-validate.yml` (new `invariants` job),
  `scripts/hooks/commit-msg` (recognise the trailer alongside the env var),
  a shared branch-name check script, `scripts/hooks/pre-push` and
  `scripts/install-hooks` (new hook), `scripts/hooks/commit-msg.test.sh` and a
  new branch-name test, `scripts/specforge` (sync commit gains the trailer),
  `docs/operating-model.md` and `docs/architecture.md`.
- Behavioural change for contributors: planning commits must use a Conventional
  subject plus the `SpecForge-Writer: planning` trailer; the `plan:` prefix is
  retired. A branch that does not match the convention fails CI.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
