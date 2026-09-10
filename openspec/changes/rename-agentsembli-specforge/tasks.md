# Tasks

## 1. Clean successor repository

- [ ] TASK-ASR-001 Verify `JoMe92/agentsembli-specforge` is empty and private, push only the allowlisted sanitized heads/tags from the clean mirror, enable and verify private vulnerability reporting, then fresh-mirror-clone and prove zero legacy PR/Dolt refs, forbidden paths, credential signatures, private/local identities and maintainer paths while the repository remains private.
- [ ] TASK-ASR-002 Add a checked-in, redacted migration record with backup location/restore procedure, old-repository risk and retirement choices, exact pushed-ref inventory, scan commands/results and rollback boundary; verify it contains no secret, personal email, private absolute path, raw Beads note or internal conversation content.

## 2. Identity and compatibility

- [ ] TASK-ASR-003 Change the canonical identity to Agentsembli SpecForge and `JoMe92/agentsembli-specforge` across package metadata, CLI output, README, maintained docs, templates, agent instructions, workflows, support/security destinations and release text while retaining `specforge` runtime identifiers; add an allowlisted legacy-URL/name scan and verify all maintained links resolve.
- [ ] TASK-ASR-004 Implement and document the compatibility transition from legacy SpecForge-tag installation to Agentsembli SpecForge, including update, rollback and removal; verify in throwaway repositories that OpenSpec, Beads, configuration, service identity and unrelated Claude/Codex/Pi settings are preserved.

## 3. Release and owner cutover

- [ ] TASK-ASR-005 Add an exact owner-run GitHub cutover checklist covering description/topics, default branch, Issues, private vulnerability reporting, releases, local remotes, old-repository archive/delete, successor visibility and rollback; verify no automated command changes visibility, signs acceptance or republishes dirty backup/legacy refs.
- [ ] TASK-ASR-006 Create a new successor release-candidate tag and unsigned acceptance report covering clean exact-tag GitHub install, legacy upgrade, rollback, uninstall, every supported agent path, canonical links, package contents and a fresh advertised-ref audit; run all mechanical gates, record deviations as Beads, obtain later owner sign-off, and verify the old repository remains private or deleted before the successor may become public.
