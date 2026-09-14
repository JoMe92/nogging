# Public-data audit — 2026-09-09

Status: **blocked pending owner decision**

This report records the pre-publication review without reproducing credentials,
personal addresses, conversation content, or Beads notes. It is an inventory
and decision record, not proof that the repository is safe to make public.

## Scope and method

The audit was run from `feat/public-release-readiness` against every ref
advertised by `origin` on 2026-09-09. The advertised set comprised the code
branches, release tags `v1.0.0` through `v1.4.0`, two pull-request heads,
`refs/dolt/data`, and `refs/heads/__dolt_remote_info__`. The pull-request heads
and Dolt data ref were fetched into temporary local `refs/audit/*` names so
that `git rev-list --all` covered their reachable objects.

The following checks were performed:

1. `git ls-remote --refs origin` inventoried all remotely reachable refs.
2. `git rev-list --all`, `git log --all`, `git grep` and path history inspected
   every reachable Git commit for credential signatures, credential-bearing
   URLs, private-key markers, email addresses, absolute home paths, private
   URLs, generated host artifacts, source notes, acceptance evidence and
   tracked Beads interactions.
3. The fetched `refs/dolt/data` tree and `__dolt_remote_info__` metadata were
   inventoried. All 217 Beads records and six persistent memories exposed by
   the local Dolt state were reviewed by field and scanned without printing
   their values into this report.
4. `.beads/interactions.jsonl`, `docs/source/`, `docs/acceptance/`, execution
   logs, `.nogging/`, and the generated root `systemd/` unit were reviewed
   separately because they can contain operational or human context.
5. `npm pack --dry-run --json` inspected the exact package payload. The
   payload was scanned using the same path and content rules.

The high-confidence credential rules covered GitHub tokens, common AI-provider
keys, AWS and Google key identifiers, PEM private keys, and URLs containing
inline credentials. Broader keyword results were manually classified to avoid
treating security documentation and test cases as secrets.

## Results

### Credentials

No live high-confidence credential was identified. The only high-confidence
pattern location was `scripts/session.test.sh`, where synthetic values are
deliberately used to test redaction. No URL host or email domain was present in
the current `docs/source/` files or `.beads/interactions.jsonl`.

This result does not replace provider-side credential rotation when there is
independent reason to suspect exposure.

### Personal and environment-specific data

The reachable commit metadata contains a public GitHub no-reply identity, a
personal contact identity, and a Raspberry Pi-local identity. The report does
not repeat the addresses. Making all current refs public would expose those
identities across historical commits.

The current tree also contains environment-specific evidence:

- `systemd/specforge-sync.service` embeds the maintainer's absolute home and
  checkout paths.
- `docs/acceptance/2026-09-02-raspberrypi.md` identifies a host class and
  architecture. This is legitimate acceptance evidence but must be replaced
  or explicitly accepted before publication.
- Historical commits retain the same host-specific service and acceptance
  context even if current-ref cleanup removes it.

### Internal source and conversation material

`docs/source/konversation-export.md`, the other `docs/source/` handoff/research
notes, and historical execution logs are reachable from existing history and
are currently included by the broad package manifest. They contain internal
planning and agent-session context that is not required by end users. The
current-ref and package copies can be removed by `TASK-PUB-003` and
`TASK-PUB-009`; their historical copies remain reachable unless the owner
accepts publication or separately approves a history rewrite.

### Beads and Dolt

The remote advertises both `refs/dolt/data` and its metadata branch. The Dolt
tree is a binary database payload rather than a normal source tree, so ordinary
working-tree secret scanners do not inspect it. The corresponding 217 issue
records, their notes, and six memories were therefore reviewed through `bd`.
No high-confidence credential signature was found, but the records contain
internal implementation history, operational decisions and agent context.
Publication of that history requires an explicit owner decision; deleting the
JSONL export alone would not remove the Dolt ref.

### Package payload

The dry-run package currently includes internal source notes, historical
acceptance material, a Python bytecode cache and generated host-specific
artifacts. This is a current-ref packaging defect, not evidence of a secret.
It is assigned to the already planned cleanup and package-allowlist tasks.

## Findings and decisions required

| ID | Finding | Current disposition |
| --- | --- | --- |
| PDA-001 | Personal and local commit identities are present throughout reachable history. | **Blocker:** owner must explicitly accept their publication or approve a separate identity/history migration. |
| PDA-002 | Internal conversation/source material is reachable in Git history. | **Blocker:** remove it from current refs, then owner must accept historical exposure or approve a separate history rewrite. |
| PDA-003 | Dolt/Beads history is advertised as a public Git ref and contains internal operational context. | **Blocker:** owner must decide whether to publish, replace, or migrate this ref before visibility changes. |
| PDA-004 | Host-specific unit, acceptance evidence, bytecode and internal docs enter the current package. | Assigned to `TASK-PUB-003` and `TASK-PUB-009`; no destructive rewrite is needed for the current payload. |
| PDA-005 | Synthetic credential-shaped strings exist in redaction tests. | Accepted exception: required negative-test fixtures, never real credentials, and safe to publish. |

## Stop condition

No history, tag, pull-request ref, or Dolt ref was rewritten or deleted. The
repository must remain private until PDA-001 through PDA-003 have explicit
owner dispositions and any approved remediation has been designed, backed up,
executed, rescanned, and coordinated as a separate destructive operation.
