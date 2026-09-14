# Agentsembli SpecForge acceptance report — <YYYY-MM-DD> — <hostname>

Copy this template to `docs/acceptance/<YYYY-MM-DD>-<hostname>.md` for each run
(date the run started, short hostname of the delivery host, e.g.
`docs/acceptance/2026-09-02-raspberrypi.md`). Fill every field. Commit the
report with the `Signed-off-by:` line left **blank**; a person completes that
line in a separate commit (see `docs/acceptance.md` step 18).

## Run metadata

| Field | Value |
| --- | --- |
| Date started | <YYYY-MM-DD> |
| Host | <hostname> |
| Operator | <name> |
| Toolkit version | <`.nogging/config.json` `nogging_version`> |
| Git commit | <`git rev-parse HEAD` of the SpecForge checkout> |
| Runbook revision | <`git log -1 --format=%h -- docs/acceptance.md`> |
| Install path exercised | <`node bin/cli.js init` and/or `npx github:JoMe92/agentsembli-specforge#<tag> init`> |
| Backend | <real `bd` + `dolt` / mechanical stub only> |

## Step results

One row per `docs/acceptance.md` step. Result is `pass`, `fail`, or `skipped`.
Every row needs a note; a `fail` or `skipped` note must say why.

| # | Tag | Step | Result | Note |
| --- | --- | --- | --- | --- |
| 1 | [M] | Create a throwaway target repository | | |
| 2 | [M] | Install SpecForge from the local checkout | | |
| 3 | [M] | Assert the readiness verdict | | |
| 4 | [A] | Real-distribution install check (`npx github:`) | | |
| 5 | [M] | Open a planning session | | |
| 6 | [A] | Author or review the change | | |
| 7 | [M] | Drop in the canned example change | | |
| 8 | [M] | Validate the change | | |
| 9 | [M] | Materialize the example's Beads | | |
| 10 | [A] | Execute a task with specialist delegation | | |
| 11 | [M] | Close the planning session | | |
| 12 | [M] | Simulate the closure and run the mechanical sync | | |
| 13 | [M] | Assert sync idempotency | | |
| 14 | [A] | Review discoveries | | |
| 15 | [M] | `doctor` and `audit` are clean | | |
| 16 | [M] | Tear down | | |
| 17 | [A] | Write the acceptance report | | |
| 18 | [A] | Product Owner sign-off | | |

Mechanical-subset shortcut: if `scripts/acceptance.sh` (or
`scripts/acceptance.sh --mechanical`) was used, record its exit status and
paste the `covered [M] runbook steps: …` line; the `[M]` rows it covered may
reference that run instead of repeating each assertion.

## Deviations

Anything done differently from `docs/acceptance.md` — a substituted command, a
skipped step, an environment difference, a manual workaround. `None` if the run
followed the runbook exactly.

- <deviation, or `None`>

## Discoveries filed during this run

Every discovery recorded on a Bead during the run (`bd update <id> --add-label
discovery --append-notes "…"`), with its Bead ID and a one-line summary. These
are **not** fixed in the acceptance change — they wait for a planning session.
`None` if the run filed no discoveries.

| Bead ID | Blocking? | Summary |
| --- | --- | --- |
| <SPEC-…> | <yes/no> | <what was found> |

## Outcome

- **Overall:** <pass / pass-with-deviations / fail>
- **Summary:** <one paragraph: what the run proves, and what (if anything) it did not>

## Sign-off

A signed report is what marks the toolkit accepted for this run. Leave this line
blank in the commit that adds the report; a person fills it in a later commit.

Signed-off-by:
