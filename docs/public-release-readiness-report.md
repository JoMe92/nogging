# Nogging public-release readiness report

**Date:** 2026-09-14
**Prepared by:** Claude (Lead Agent), directed by the Product Owner
**Change:** `public-release-readiness`
**Head commit at report time:** `bc13e5040df43560f38c17ed2353d9439d463171` on
`test/public-release-readiness`, delivered as
[PR #5](https://github.com/JoMe92/nogging/pull/5) (open, not merged)

## Purpose

This report proves TASK-PUB-001 through TASK-PUB-014, states the CI gate
status accurately (including one gate that is not yet green), lists reviewed
discoveries, confirms clean package contents, points at the current release
evidence, and confirms the required identity statements. It ends with an
owner-only checklist. **It does not change repository visibility, and the
repository remains private.**

## TASK-PUB-001 through TASK-PUB-014

All fourteen closed, each with a commit and a Bead evidence note.

| Task | Bead | What it delivered |
| --- | --- | --- |
| TASK-PUB-001 | SPEC-1znl | Full ISC license, copyright, third-party notices |
| TASK-PUB-002 | SPEC-28u5 | Credential/privacy audit across Git, Dolt, package, reports |
| TASK-PUB-003 | SPEC-dc4u | Sanitized current-ref operational artifacts, regression checks |
| TASK-PUB-004 | SPEC-xdnw | Superseded — implemented via `rename-to-nogging`'s TASK-NOG-011 (`CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, issue/PR templates) |
| TASK-PUB-005 | SPEC-exvr | Remaining README readiness sections (maturity, audience, safety, doc index), on top of `rename-to-nogging`'s TASK-NOG-010 base README |
| TASK-PUB-006 | SPEC-wkiz | Install/operations docs reconciled with current behavior |
| TASK-PUB-007 | SPEC-w4fe | Public security/threat-model guide |
| TASK-PUB-008 | SPEC-4ss7 | GitHub-only distribution, `prepublishOnly` guard, package metadata |
| TASK-PUB-009 | SPEC-r0m3 | Minimized package payload, clean-checkout manifest test |
| TASK-PUB-010 | SPEC-xhuy | CLI version/update/rollback/remove lifecycle commands |
| TASK-PUB-011 | SPEC-n4jw | Documented compatibility policy and matrix |
| TASK-PUB-012 | SPEC-3xh9 | CI hardening (pinned action SHAs, least-privilege permissions, Dependabot, security gates) — found and fixed a real Python 3.9 `recover()` bug the new matrix caught |
| TASK-PUB-013 | SPEC-n3si | Repeatable release process: `CHANGELOG.md`, `scripts/release-check`, `scripts/release-artifacts`, `scripts/release-smoke-test`, `docs/releasing.md` |
| TASK-PUB-014 | SPEC-gbp2 | Release candidate `v2.0.0-rc.2` tagged and pushed; full mechanical + real-tag lifecycle acceptance; found and fixed a real v1→v2 upgrade defect (legacy `.specforge/` migration) |

## CI gate status — accurate, not all green yet

- **`test/public-release-readiness` branch / PR #5: fully green.** 30 required
  checks pass, 2 skip as expected (trigger-conditional jobs). Verified at
  `gh pr checks 5` and the rollup of `statusCheckRollup` on the PR.
- **`develop`'s current tip is red**, and will remain so until PR #5 merges.
  The failing commits on `develop` (`08469b7`, `4a441e6`, pushed before this
  branch existed) carry the same Python 3.9 `recover()` bug TASK-PUB-012
  found and fixed here (commit `c9d840e`) — the fix has not reached `develop`
  yet because it lives on this unmerged branch.
- **This is not a new problem introduced by this change** — it is the reason
  the fix needs to land. Reported honestly rather than claimed clean.

**Action needed:** merge PR #5. Once merged, `develop`'s next CI run is
expected green (identical commits already pass on the PR).

## Discoveries reviewed

`./scripts/nogg discoveries`: 1 blocking, already known and unrelated —
`SPEC-c4o5`, "Sanitize Git and Dolt history before public release," blocked
on GitHub's refusal to delete hidden merged-PR refs (`refs/pull/1/head`,
`refs/pull/2/head`). Requires an owner decision (GitHub Support ticket, or
delete-and-recreate the still-private repository) before any future public
launch. **Out of scope for this readiness report** — it blocks a *future*
public-visibility change, not this change's own completion, and the
repository stays private regardless.

No other new discoveries are pending review; the 37 "closed, awaiting
review" entries `discoveries` also lists predate this change and were
already folded into earlier changes or acknowledged in prior planning
sessions.

## Package contents

- `scripts/package-publication.test.sh`: pass — GitHub-only distribution
  policy enforced, `npm publish --dry-run` cannot publish.
- `scripts/public-tree.test.sh`: pass — no forbidden path, private host
  path, or internal-only artifact in the public tree or package payload.

## Release evidence

- Release candidate: **`v2.0.0-rc.2`**, pushed to `JoMe92/nogging`
  (`v2.0.0-rc.1` was pushed, found broken by acceptance testing, deleted,
  and superseded).
- Acceptance report: `docs/acceptance/2026-09-14-raspberrypi.md` —
  mechanical suite green with a real `bd`+`dolt` backend, real
  `npx github:JoMe92/nogging#v2.0.0-rc.2` install verified, upgrade from
  `v1.6.0` verified (after a fix), uninstall preservation verified.
  **`Signed-off-by:` is intentionally blank** — see the owner checklist.
- `scripts/release-artifacts`: package tarball, SHA-256 checksum, and a
  CycloneDX SBOM generated for `2.0.0-rc.2` (git-ignored under
  `dist/release/`, not committed — regenerate with `scripts/release-artifacts`
  whenever needed).

## Required identity statements

Confirmed present in `README.md` and `docs/project-identity.md`: **Nogging**
as the canonical public name; Gas Town credited as conceptual inspiration
with a direct link; Nogging stated as an independent implementation, not
affiliated with or endorsed by the Gas Town or Beads maintainers; **Beads**
identified as the only Gas Town-ecosystem component currently adopted.

## Owner-only checklist

None of the following were performed automatically. All require an explicit
decision by the Product Owner.

- [ ] **Review and merge [PR #5](https://github.com/JoMe92/nogging/pull/5)**
      into `develop` (fast-forward or merge commit, operator's choice) —
      this is what makes `develop`'s CI green again.
- [ ] **Sign the acceptance report**: add a `Signed-off-by:` line to
      `docs/acceptance/2026-09-14-raspberrypi.md` in a separate commit
      (`docs/acceptance.md` step 18).
- [ ] **Decide on `SPEC-c4o5`** (hidden GitHub pull-ref history) before any
      future public-visibility change — unrelated to this report, listed
      here only so it isn't lost.
- [ ] **Optional: enable the repository's Dependency graph** (Settings →
      Security → Dependency graph, and GitHub Advanced Security if this
      account/plan requires it for a private repo) to make the
      `dependency-review` CI job enforce instead of its current
      `continue-on-error` degrade — found while opening PR #5. `npm audit`
      (`scripts/ci-security-gates.sh dependencies`) already enforces
      dependency vulnerabilities regardless.
- [ ] **Repository visibility remains private.** Changing it is an
      explicit, separate, future owner decision this report does not make
      or recommend a timeline for.

## Outcome

**Not yet accepted — one merge and one signature away.** Every mechanically
and agent-verifiable gate this report can check is either green or has an
accurately reported reason it is not (the unmerged-PR CI gap on `develop`,
the acceptance sign-off, and the pre-existing, unrelated `SPEC-c4o5`
history-sanitization block). The repository is confirmed still private.
