# Nogging acceptance report — 2026-09-14 — raspberrypi

## Run metadata

| Field | Value |
| --- | --- |
| Date started | 2026-09-14 |
| Host | raspberrypi |
| Operator | Claude (Lead Agent), directed by the Product Owner |
| Toolkit version | 2.0.0-rc.2 |
| Git commit | e1facf60e3f04519479d7017ef9b7a8e62216c40 |
| Runbook revision | 65dc3b9 |
| Install path exercised | both: `node bin/cli.js init` (local checkout) and `npx github:JoMe92/nogging#<tag> init` (real tags `v1.6.0` and `v2.0.0-rc.2`) |
| Backend | real `bd` 1.2.2 + `dolt` 2.3.1 |

## Step results

`scripts/acceptance.sh` (full mode, real backend) exit 0, covering:
`covered [M] runbook steps: 1 2 3 5 7 8 9 11 12 13 15 16`.

| # | Tag | Step | Result | Note |
| --- | --- | --- | --- | --- |
| 1 | [M] | Create a throwaway target repository | pass | via `scripts/acceptance.sh` |
| 2 | [M] | Install Nogging from the local checkout | pass | via `scripts/acceptance.sh`; readiness verdict asserted |
| 3 | [M] | Assert the readiness verdict | pass | `Nogging is ready — run ./scripts/nogg plan-begin to start.` |
| 4 | [A] | Real-distribution install check (`npx github:`) | pass | `npx --yes github:JoMe92/nogging#v2.0.0-rc.2 init` in a fresh throwaway repo, and again via `scripts/release-smoke-test`; both report ready |
| 5 | [M] | Open a planning session | pass | via `scripts/acceptance.sh` |
| 6 | [A] | Author or review the change | pass | canned example fixture stands in, as the runbook allows |
| 7 | [M] | Drop in the canned example change | pass | via `scripts/acceptance.sh` |
| 8 | [M] | Validate the change | pass | via `scripts/acceptance.sh` |
| 9 | [M] | Materialize the example's Beads | pass | 2 tasks materialized, via `scripts/acceptance.sh` |
| 10 | [A] | Execute a task with specialist delegation | pass-with-deviation | the Lead Agent (this session) implemented directly rather than delegating to a specialist subagent — see Deviations |
| 11 | [M] | Close the planning session | pass | via `scripts/acceptance.sh` |
| 12 | [M] | Simulate the closure and run the mechanical sync | pass | via `scripts/acceptance.sh` |
| 13 | [M] | Assert sync idempotency | pass | via `scripts/acceptance.sh` |
| 14 | [A] | Review discoveries | pass | `./scripts/nogg discoveries`: 1 blocking (`SPEC-c4o5`, unrelated pre-existing public-history-sanitization discovery, out of scope for this change; not a product of this run) |
| 15 | [M] | `doctor` and `audit` are clean | pass | via `scripts/acceptance.sh` |
| 16 | [M] | Tear down | pass | via `scripts/acceptance.sh` |
| 17 | [A] | Write the acceptance report | pass | this document |
| 18 | [A] | Product Owner sign-off | pending | see Sign-off |

### Additional TASK-PUB-014 lifecycle coverage (beyond the base runbook)

Run against the real pushed tags, in a throwaway repository, outside `scripts/acceptance.sh`:

- **Upgrade from the preceding release**: `npx github:JoMe92/nogging#v1.6.0 init` →
  seed owner-owned `openspec/changes/owner-change/proposal.md` →
  `npx github:JoMe92/nogging#v2.0.0-rc.2 update`. **Result: pass** (after a fix —
  see Deviations). Verified: `.specforge/` migrated to `.nogging/` in place,
  `nogging_version` recorded as `2.0.0-rc.2`, owner-owned state untouched.
- **Rollback within a major version**: covered by `scripts/release-lifecycle.test.sh`
  (`1.6.0` ⇄ `1.7.0` fixture versions), part of `scripts/test`. **Result: pass.**
- **Rollback across the v1→v2 boundary**: `npx github:JoMe92/nogging#v1.6.0 update`
  against a `.nogging`-only (post-migration) target. **Result: not supported —
  by design**, not a defect: v1.6.0's own `update` only recognizes
  `.specforge/config.json`, and downgrading across a breaking major version is
  not expected to be seamless under semver. Documented here rather than in a
  Bead because it is an accepted limitation, not something to fix.
- **Uninstall preservation**: `npx github:JoMe92/nogging#v2.0.0-rc.2 remove` against
  the upgraded target. **Result: pass** — target-owned `openspec/`, `.beads`,
  and `.nogging/config.json` all survived removal.
- **Beads hook interaction**: covered by the existing `scripts/hooks/*.test.sh`
  suite (part of `scripts/test`, unchanged by this run) plus the `core.hooksPath`
  warning surfaced correctly in every install above. **Result: pass.**
- **Recovery**: `./scripts/nogg doctor --recover` / `recover` behavior is
  covered by `scripts/nogg.test.sh` (part of `scripts/test`). Not independently
  re-run against a live throwaway repo in this session beyond what
  `scripts/acceptance.sh` already exercises via `doctor`/`audit`.
- **Claude/Codex/Pi paths**: mechanically verified — the installer's file
  manifest ships the Claude, Codex, and Pi payloads (agents, prompts, guard
  extension, rules) and `scripts/cli.test.sh` / `scripts/session.test.sh`
  assert each is written and functions in isolation (part of `scripts/test`,
  unchanged by this run). **Not independently verified**: an actual live
  Codex or Pi agent session in this run — this session is Claude Code only.
  That live-session verification is the same [A] gap the 2026-09-10 report
  recorded for the equivalent step; it still requires a human or an agent
  session of that specific kind to close.

## Deviations

- **Step 10** — no separate specialist subagent was delegated; the Lead Agent
  (this session) implemented every task directly. Same deviation the
  2026-09-10 report recorded.
- **A real bug was found and fixed during step "upgrade from the preceding
  release"**: `update` refused outright (`no .nogging/config.json — run init
  first`) against a real v1.6.0 install, because it only recognized the new
  `.nogging/` state root and had no path for the pre-rename `.specforge/`
  root. Fixed in commit `470adc6` (`migrateLegacyStateRoot`, called from both
  `init` and `update`) — see `CHANGELOG.md` under `2.0.0-rc.2`. The first
  release-candidate tag, `v2.0.0-rc.1`, was pushed without this fix, found
  broken by this exact acceptance check, and was deleted and superseded by
  `v2.0.0-rc.2` (which includes the fix) rather than left on the tag list.
- **Live Codex/Pi agent-session verification** was not performed (see the
  Claude/Codex/Pi row above) — this run is Claude-Code-only.
- No other deviation from `docs/acceptance.md`.

## Discoveries filed during this run

| Bead ID | Blocking? | Summary |
| --- | --- | --- |
| None | — | The `.specforge/` → `.nogging/` upgrade defect found during this run was fixed directly within `TASK-PUB-014` (`SPEC-gbp2`, commit `470adc6`) rather than filed as a separate discovery, since it was resolved before this report was written. |

## Outcome

- **Overall:** pass-with-deviations
- **Summary:** The mechanical runbook subset passes end-to-end with a real
  `bd`/`dolt` backend (`scripts/acceptance.sh`, full mode). The real,
  GitHub-tagged `npx github:JoMe92/nogging#v2.0.0-rc.2` install path works and
  reports ready. A real, previously-unverified defect in the v1→v2 upgrade
  path was found by this run and fixed before the report was written, and the
  broken `v2.0.0-rc.1` tag was replaced by the fixed `v2.0.0-rc.2`. Rollback
  within a major version, and uninstall preservation, both pass; rollback
  across the v1→v2 boundary is intentionally unsupported, consistent with a
  breaking major-version release. The run does not independently verify a
  live Codex or Pi agent session — that remains open, as it was in the prior
  report.

## Sign-off

Signed-off-by:
