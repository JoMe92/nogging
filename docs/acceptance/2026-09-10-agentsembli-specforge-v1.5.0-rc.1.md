# Agentsembli SpecForge acceptance report — 2026-09-10 — release candidate

## Run metadata

| Field | Value |
| --- | --- |
| Date started | 2026-09-10 |
| Host | Redacted delivery host |
| Operator | Automated Main Worker; owner actions excluded |
| Toolkit version | `1.5.0-rc.1` |
| Candidate tag | `v1.5.0-rc.1` |
| Tag target | `f161de078e102a1833c34fa92f04f7a5120297b0` |
| Install path exercised | `npx github:JoMe92/agentsembli-specforge#v1.5.0-rc.1 init` |
| Backend | Mechanical test stubs; no production Beads/Dolt mutation |

## Results

| Area | Result | Evidence |
| --- | --- | --- |
| Clean exact-tag GitHub install | pass | A new temporary Git repository installed the private GitHub tag; the executable, Agentsembli SpecForge instructions, and `1.5.0-rc.1` installed version were verified. |
| Legacy update | pass | `scripts/rename-compatibility.test.sh` installed sanitized `v1.4.0`, updated from the current successor tree, and preserved target-owned state. |
| Rollback | pass | The same test updated back to sanitized `v1.4.0` without changing OpenSpec, Beads, configuration, services, or unrelated agent settings. |
| Removal | pass | The same test updated again and ran `remove`; managed payload was deleted while target-owned state remained. |
| Claude Code path | pass | Installer and boundary suites verified shipped agents, commands, settings merge, and OpenSpec guard. |
| Codex path | pass | Installer and command suites verified rules, prompts, hook preservation, and prompt-link lifecycle. |
| Pi path | pass | Installer and guard suites verified prompts, extension payload, and guard behavior where the host Node runtime supports direct TypeScript loading. |
| Canonical identity and links | pass | Identity scan limits the legacy URL to two transition documents; canonical repositories resolved through GitHub and maintained relative Markdown links resolved locally. |
| Package contents | pass | GitHub-only publication and public-tree gates passed; npm publication remains fail-closed and private/internal artifacts are excluded. |
| Advertised refs and history | pass | A fresh private successor mirror advertised 18 branch/tag refs only; forbidden paths, local/private commit identities, maintainer paths, credential signatures, and object errors were absent. |
| Candidate integrity | pass | Remote peeled tag target equals `f161de078e102a1833c34fa92f04f7a5120297b0`. |
| Full mechanical suite | pass | `scripts/test` passed after the candidate changes and report were added. |

Mechanical runbook coverage: steps 1, 2, 3, 5, 7, 8, 9, 11, 12, 13,
15, and 16 passed through `scripts/acceptance.test.sh`. Distribution,
compatibility, agent-path, identity, package, and history checks above extend
that mechanical subset for the rename candidate.

## Deviations and pending owner actions

- The repository remained private throughout automation.
- GitHub Private Vulnerability Reporting cannot be enabled during the private
  phase. The owner checklist requires enabling and verifying it immediately
  after making the repository public.
- No GitHub Release was published. The owner must publish the prepared release
  only during the cutover sequence.
- The legacy repository was not archived or deleted by automation; it remains
  private pending the owner's chosen retirement action.
- No human Product Owner acceptance was performed.

## Discoveries filed during this run

| Bead ID | Blocking? | Summary |
| --- | --- | --- |
| `SPEC-412j` | resolved before publication | New rename commits inherited a private local Git email. The private remote branch and RC tag were rewritten to the public GitHub noreply identity, and the fresh mirror audit then passed. |
| `SPEC-412j` | no | The legacy-URL scan needed to allowlist both explicit transition documents: the migration record and owner cutover checklist. |

## Outcome

- **Overall:** pass-with-deviations
- **Summary:** The private `v1.5.0-rc.1` candidate is mechanically ready for
  the owner-run cutover. Public visibility, immediate Private Vulnerability
  Reporting enablement, release publication, legacy retirement, and final
  acceptance remain intentionally pending.

## Sign-off

Signed-off-by:
