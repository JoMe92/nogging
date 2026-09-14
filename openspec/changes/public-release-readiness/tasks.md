# Tasks

## 1. Legal and public-data gates

- [x] TASK-PUB-001 Add the full ISC license and copyright identity, inventory bundled/generated third-party material, add required notices plus a vendor non-affiliation statement, and verify GitHub/package license detection and every distributed component's license compatibility.
- [x] TASK-PUB-002 Run a reproducible credential/privacy audit across every advertised Git ref, complete Git history, package payload, `.beads/interactions.jsonl`, `refs/dolt/data`, `__dolt_remote_info__`, acceptance reports, execution logs, and `docs/source/`; commit a redacted audit report listing tools, scope, findings, accepted exceptions, and blockers, and stop with a discovery rather than rewriting history if destructive remediation is required.
- [x] TASK-PUB-003 Remove or sanitize current-ref operational artifacts found unsuitable by TASK-PUB-002, including host-specific generated systemd units and internal/package-only documents; add regression checks that prevent their return, and verify the public tree and package contain no private host path or forbidden artifact.

## 2. Public documentation and governance

- [x] TASK-PUB-004 (superseded — implemented via `rename-to-nogging`'s TASK-NOG-011) Add `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, support guidance, issue forms, a pull-request template, and documented GitHub description/topics/settings; verify each contributor and disclosure path is internally consistent and link-valid without changing repository visibility.
- [x] TASK-PUB-005 Extend the Nogging `README.md` (rewritten by `rename-to-nogging` TASK-NOG-010) with remaining readiness sections: maturity status, audience, supported agents/platforms, safety warning, documentation index; keep the Gas Town/Beads provenance note and Agent Console as an optional sibling mention; verify the example succeeds in a fresh repository without a product website, Agent Console installation, or maintainer-local path.
- [x] TASK-PUB-006 Reconcile installation and operations documentation with current behavior: automatic Beads initialization and `--no-beads`, all Claude/Codex/Pi payloads, OpenSpec and runtime prerequisites, slugged systemd services, hook collision, pinned update, rollback, uninstall, and non-systemd operation; verify documented commands against CLI help and a fresh install.
- [x] TASK-PUB-007 Write a public security/threat-model guide covering installed hooks and instructions, background services, network and filesystem authority, command floors, credentials, trust dialogs, restricted/trusted/orchestrator modes, vendor-specific residual risk, and safe disable/removal; verify README and `SECURITY.md` route users to it before full-access commands.

## 3. Distribution and usability

- [x] TASK-PUB-008 Make the first public distribution explicitly GitHub-only by preventing accidental npm publication and documenting the occupied unscoped npm name; complete package repository/homepage/bugs/author/keywords metadata and verify `npm publish --dry-run` cannot publish while tagged `npx github:` installation still works.
- [x] TASK-PUB-009 Replace broad package inclusion with an explicit minimal runtime/user-doc payload, include the missing Pi guide, exclude caches/bytecode/internal research/acceptance history/generated local units, and add a clean-checkout package manifest test that proves every required file and no forbidden file is packed.
- [ ] TASK-PUB-010 Add a CLI version command or flag plus tested update-to-tag, rollback-to-tag, and uninstall/removal behavior that preserves target-owned OpenSpec, Beads, config, and unrelated agent settings; verify all lifecycle scenarios in throwaway repositories.

## 4. Compatibility, CI, and releases

- [ ] TASK-PUB-011 Define a compatibility policy and matrix for Node, Python, Git, Bash, OpenSpec, Beads, Dolt, tmux, systemd, architectures, operating systems, and Claude/Codex/Pi versions; align declared engine constraints and doctor output, then verify every supported automated combination in CI or link to current manual evidence.
- [ ] TASK-PUB-012 Harden GitHub automation with least-privilege permissions, immutable action revisions, dependency update automation, dependency/security scans, secret and package-content checks, and Markdown link validation; verify an intentionally bad fixture makes each new gate fail and normal CI remains green.
- [ ] TASK-PUB-013 Add a documented repeatable release process with `CHANGELOG.md`, version/tag/release consistency checks, verifiable tags, generated checksums and SBOM or an explicit not-applicable result, and an exact-tag post-release install smoke test; verify the workflow in a non-public release-candidate dry run.

## 5. Acceptance and owner handoff

- [ ] TASK-PUB-014 Produce a new release-candidate tag and dated acceptance report covering clean tagged GitHub install, upgrade from the preceding release, rollback, uninstall preservation, Beads hook interaction, recovery, and every declared-supported Claude/Codex/Pi path; run the mechanical suite, record every deviation with a Bead, commit the report unsigned, and obtain the required later human sign-off before marking it accepted.
- [ ] TASK-PUB-015 Generate a final public-readiness report proving TASK-PUB-001 through TASK-PUB-014, all CI gates, zero unresolved publication blockers, reviewed pending discoveries, signed acceptance, clean package contents, current release evidence, and the required Nogging/Gas Town/Beads identity statements; include an owner-only GitHub visibility checklist and verify the repository is still private when this task closes—do not change visibility or automate that action.
