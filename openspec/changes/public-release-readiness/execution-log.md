# Execution log

<!-- specforge:SPEC-4ss7:2026-09-10T16:24:04Z -->
- 2026-09-10T19:03:57+00:00 — SPEC-4ss7 closed for TASK-PUB-008 (Bead closed at 2026-09-10T16:24:04Z).
  - implementation commits: 58d548a85573, d23a15784da9f6e14ef59b526712d71f3c559f58
  - Bead note:
    progress: claimed on feat/public-release-readiness after integrating TASK-IDENT-004; next harden package metadata against npm publication and add package/dry-run/tagged-GitHub install regression coverage
    commit d23a15784da9f6e14ef59b526712d71f3c559f58; package.json is private, has a fail-closed prepublishOnly guard and complete repository/homepage/bugs/author/keyword metadata; README documents the occupied unscoped npm name and pinned GitHub-only install. Evidence: bash scripts/package-publication.test.sh passed; npm publish --dry-run failed with the intended route; npx --yes github:JoMe92/specforge#v1.4.0 --help succeeded; scripts/test passed in full.

<!-- specforge:SPEC-1znl:2026-09-09T20:20:19Z -->
- 2026-09-10T19:03:57+00:00 — SPEC-1znl closed for TASK-PUB-001 (Bead closed at 2026-09-09T20:20:19Z).
  - implementation commits: d4281b860f5c, ca7798d
  - Bead note:
    Implemented in ca7798d. Evidence: scripts/legal.test.sh passed; full scripts/test passed; npm pack dry-run includes LICENSE and THIRD_PARTY_NOTICES.md; Beads upstream MIT license verified from gastownhall/beads; root/package license both ISC.

<!-- specforge:SPEC-28u5:2026-09-09T20:28:08Z -->
- 2026-09-10T19:03:57+00:00 — SPEC-28u5 closed for TASK-PUB-002 (Bead closed at 2026-09-09T20:28:08Z).
  - implementation commits: f64c1eca4cde, 1439c3a
  - Bead note:
    progress: inventory advertised Git and Dolt refs, then run redacted credential/privacy scans without rewriting history
    Audit report committed in 1439c3a. Evidence: all origin-advertised refs (including two pull refs, refs/dolt/data and __dolt_remote_info__), complete reachable Git history, 217 Beads records, six memories, interactions JSONL, source/acceptance/execution material, and npm dry-run payload were inventoried and scanned. No live high-confidence credential was found; synthetic token fixtures are accepted. Blocking discovery: reachable history exposes personal/local commit identities and internal conversation/source material, while the advertised Dolt ref exposes internal operational history. Owner must explicitly accept each exposure or separately approve a destructive history/Dolt migration; no ref was rewritten or deleted.

<!-- nogg:SPEC-4ss7:2026-09-10T16:24:04Z -->
- 2026-09-14T18:22:32+00:00 — SPEC-4ss7 closed for TASK-PUB-008 (Bead closed at 2026-09-10T16:24:04Z).
  - implementation commits: 58d548a85573, d23a15784da9f6e14ef59b526712d71f3c559f58
  - Bead note:
    progress: claimed on feat/public-release-readiness after integrating TASK-IDENT-004; next harden package metadata against npm publication and add package/dry-run/tagged-GitHub install regression coverage
    commit d23a15784da9f6e14ef59b526712d71f3c559f58; package.json is private, has a fail-closed prepublishOnly guard and complete repository/homepage/bugs/author/keyword metadata; README documents the occupied unscoped npm name and pinned GitHub-only install. Evidence: bash scripts/package-publication.test.sh passed; npm publish --dry-run failed with the intended route; npx --yes github:JoMe92/specforge#v1.4.0 --help succeeded; scripts/test passed in full.

<!-- nogg:SPEC-1znl:2026-09-09T20:20:19Z -->
- 2026-09-14T18:22:32+00:00 — SPEC-1znl closed for TASK-PUB-001 (Bead closed at 2026-09-09T20:20:19Z).
  - implementation commits: d4281b860f5c, ca7798d
  - Bead note:
    Implemented in ca7798d. Evidence: scripts/legal.test.sh passed; full scripts/test passed; npm pack dry-run includes LICENSE and THIRD_PARTY_NOTICES.md; Beads upstream MIT license verified from gastownhall/beads; root/package license both ISC.

<!-- nogg:SPEC-28u5:2026-09-09T20:28:08Z -->
- 2026-09-14T18:22:32+00:00 — SPEC-28u5 closed for TASK-PUB-002 (Bead closed at 2026-09-09T20:28:08Z).
  - implementation commits: f64c1eca4cde, 1439c3a
  - Bead note:
    progress: inventory advertised Git and Dolt refs, then run redacted credential/privacy scans without rewriting history
    Audit report committed in 1439c3a. Evidence: all origin-advertised refs (including two pull refs, refs/dolt/data and __dolt_remote_info__), complete reachable Git history, 217 Beads records, six memories, interactions JSONL, source/acceptance/execution material, and npm dry-run payload were inventoried and scanned. No live high-confidence credential was found; synthetic token fixtures are accepted. Blocking discovery: reachable history exposes personal/local commit identities and internal conversation/source material, while the advertised Dolt ref exposes internal operational history. Owner must explicitly accept each exposure or separately approve a destructive history/Dolt migration; no ref was rewritten or deleted.

<!-- nogg:SPEC-dc4u:2026-09-11T05:32:45Z -->
- 2026-09-14T18:22:32+00:00 — SPEC-dc4u closed for TASK-PUB-003 (Bead closed at 2026-09-11T05:32:45Z).
  - implementation commits: 4a7859be9c71, 9974e8dc13a6abc81508b82bb5f7f47a154fe67f
  - Bead note:
    progress: claimed after TASK-PUB-008; next read the TASK-PUB-002 audit evidence, remove/sanitize each current-ref forbidden operational artifact, and add public-tree plus package regression checks
    During current-tree cleanup, a maintainer-specific /home/jome path was found in openspec/changes/archive/2026-09-03-agent-neutral-launch/execution-log.md. Execution agents cannot alter OpenSpec, including archived execution evidence. Suggested follow-up: the planning/owner review must explicitly classify this historical evidence as an accepted public exception or perform an authorized OpenSpec/history remediation; the new public-surface gate excludes immutable OpenSpec evidence rather than silently changing it.
    commit 9974e8dc13a6abc81508b82bb5f7f47a154fe67f; removed the generated host-specific root systemd units, internal docs/source notes, and legacy host-named acceptance report; replaced the README maintainer path; excluded internal/acceptance/bytecode paths from npm packaging; removed the generated scripts/__pycache__/specforgecpython-313.pyc; added scripts/public-tree.test.sh. Evidence: public-tree and package-publication tests passed; scripts/test passed in full. Blocked only on the recorded immutable OpenSpec historical-path discovery and the owner dispositions already required by PDA-001 through PDA-003. progress: planning/owner review records the accepted or remediated disposition for historical OpenSpec/Git/Dolt exposure, then rerun the gate and close.
    commit ; removed tracked generated host units, internal docs/source material, the stale host-specific acceptance report, and the maintainer-local README path; package exclusions and scripts/public-tree.test.sh prevent their return, including regenerated Python bytecode. Evidence: scripts/public-tree.test.sh passed, scripts/package-publication.test.sh passed, scripts/test passed in full. Blocked only on the immutable OpenSpec historical-path disposition recorded in the discovery; current user/product surfaces and package are clean.
    Correction: the complete cleanup commit SHA is 9974e8dc13a6abc81508b82bb5f7f47a154fe67f; the later note with an empty SHA was a no-op follow-up after the commit was already present.
    Owner decision (2026-09-11): the historical /home/jome path in immutable archived OpenSpec evidence is accepted as a historical exception; no history rewrite is authorised. Current public surfaces and package are covered by the regression gates.

<!-- nogg:SPEC-xdnw:2026-09-14T17:56:48Z -->
- 2026-09-14T18:22:32+00:00 — SPEC-xdnw closed for TASK-PUB-004 (Bead closed at 2026-09-14T17:56:48Z).
  - implementation commits: none found
  - Bead note:
    progress: paused before file edits; next step is governance/community files after the owner-facing product-name research and follow-up planning session resolve whether public metadata should use a new name
    Public project metadata cannot be finalized coherently until the product identity decision is made. Preliminary search found the current unscoped npm name occupied by an unrelated hardware product; owner requested a separately documented concept and claimability research. Resume after the product-identity planning decision.

<!-- nogg:SPEC-exvr:2026-09-14T18:37:43Z -->
- 2026-09-14T18:42:49+00:00 — SPEC-exvr closed for TASK-PUB-005 (Bead closed at 2026-09-14T18:37:43Z).
  - implementation commits: c7c028c34971, 80088fc
  - Bead note:
    Plan revision 80088fc: keep SpecForge as the standalone public project name; Agentsembli is only a provisional ecosystem working name; Agent Console is optional; README must directly link Gas Town and Beads, credit Gas Town as conceptual inspiration, and state independent implementation, non-affiliation, and that only Beads is currently adopted. No website, repository rename, or Agent Console install may be required.
    Retitled during OpenSpec reconciliation after rename-to-nogging: README base is now written by TASK-NOG-010, this task covers only the remaining readiness sections.
    progress: Context and dependencies reviewed; next allocate the implementation worktree, extend README with the remaining public-readiness sections, and verify the standalone quick start in a fresh repository.
    Non-blocking discovery for TASK-PUB-006: docs/project-identity.md still says Agentsembli qualifies Nogging and lists sf-<role>-<bead>-<nonce> session identifiers, although the rename established the Nogging identity and nogg-prefixed runtime surface. Reconcile that document under the installation/operations documentation task; PUB-005 remains scoped to README and its verification.
    Completed in commit c7c028c34971e89245ecee7c861ab354e101f62a. README now states maturity and audience, honest Linux/agent support boundaries, a pinned standalone quick start, safety warning, documentation index, Gas Town/Beads provenance and non-affiliation, and optional Agent Console. Verification: local fresh Git repository installed with default Beads initialization using the checkout equivalent of the pinned command; ./scripts/nogg doctor and validate passed; README relative links and required statements are enforced by scripts/nogging-identity.test.sh; full scripts/test passed.

<!-- nogg:SPEC-wkiz:2026-09-14T18:41:54Z -->
- 2026-09-14T18:42:49+00:00 — SPEC-wkiz closed for TASK-PUB-006 (Bead closed at 2026-09-14T18:41:54Z).
  - implementation commits: d850b951d992
  - Bead note:
    progress: PUB-005 is integrated and green; next reconcile installation and operations docs against current CLI/manifest behavior in an isolated task worktree, then verify help and a fresh install.
    Non-blocking dependency discovery for TASK-PUB-009: bin/lib/manifest.js installs operating-model, architecture, failure-recovery, using-with-codex, and worktree-workflow under docs/nogging, but not docs/using-with-pi.md. Installed operating-model prose links to using-with-pi.md, so the installed link is currently absent. PUB-006 will document the current payload accurately; PUB-009 already explicitly owns adding the missing Pi guide and package-manifest enforcement.
    Correction to the discovery note after source verification: sf-<role>-<bead>-<nonce> remains the intentional ordinary supervised-session shape in scripts/nogg; only the singleton orchestrator was renamed to nogg-orchestrator-<slug>. No session-name documentation change is needed. The stale Agentsembli qualifier wording remains a valid PUB-006 documentation correction.
    Completed in commit d850b951d9925cf15480773a2fbc1bdd688439c8. Reconciled installation and identity docs with pinned GitHub installation, automatic Beads init/--no-beads, Claude/Codex/Pi payloads and prerequisites, slugged sync/orchestrator units, three-hook core.hooksPath collision, pinned update/rollback/remove, and non-systemd operation. Added scripts/installation-docs.test.sh, which compares flags to CLI help and verifies fresh installs with rendered units and --no-systemd. Focused test and full scripts/test pass.

<!-- nogg:SPEC-w4fe:2026-09-14T18:50:42Z -->
- 2026-09-14T18:50:58+00:00 — SPEC-w4fe closed for TASK-PUB-007 (Bead closed at 2026-09-14T18:50:42Z).
  - implementation commits: 41ec41ffd1bf
  - Bead note:
    progress: security guide, entry-point links, regression test, and full scripts/test are complete; next commit, record evidence, close, integrate, and sync.
    Implemented in commit 41ec41ffd1bf0e8542a6da0d019afb8dafc9a099. Evidence: scripts/security-docs.test.sh passed; full scripts/test passed, including acceptance, installer, guards, sessions, package, and worktree suites; git diff --check passed.

<!-- nogg:SPEC-r0m3:2026-09-14T18:54:35Z -->
- 2026-09-14T18:54:43+00:00 — SPEC-r0m3 closed for TASK-PUB-009 (Bead closed at 2026-09-14T18:54:35Z).
  - implementation commits: 51eeb5ee67ad
  - Bead note:
    progress: explicit package allowlist, Pi/security installed docs, clean-index package manifest gate, installer assertions, and full scripts/test are complete; next commit, verify committed clean snapshot, record evidence, close, integrate, and sync.
    Implemented in commit 51eeb5ee67ad49abb1d070c8f5e1a57f4a095929. Evidence: committed clean-index scripts/package-manifest.test.sh passed; full scripts/test passed; packed installer tests prove Pi and security guides install; forbidden internal/acceptance/cache/generated paths are absent; git diff --check passed.

<!-- nogg:SPEC-xhuy:2026-09-14T18:58:13Z -->
- 2026-09-14T18:58:21+00:00 — SPEC-xhuy closed for TASK-PUB-010 (Bead closed at 2026-09-14T18:58:13Z).
  - implementation commits: f555caabc30e
  - Bead note:
    The installation payload table still described the Pi guide as future work after PUB-009 had already shipped it, and omitted the newly installed security guide. The stale statement was found while reconciling lifecycle documentation and is corrected in this task; planning should review whether any release-readiness artifact needs an explicit documentation-consistency note.
    progress: version command/flag, pinned update/rollback/remove documentation, throwaway two-release lifecycle test, and full scripts/test are complete; next commit, record evidence, close, integrate, and sync.
    Implemented in commit f555caabc30ea7a7e624ce49e291782839d40b61. Evidence: scripts/release-lifecycle.test.sh passed version, pinned update, rollback, remove, and preservation scenarios; CLI and installation documentation tests passed; full scripts/test passed; git diff --check passed.
