# Nogging acceptance runbook

This is the reproducible end-to-end procedure that validates the **whole**
Nogging toolkit against a fresh target repository: install → readiness →
planning session → materialize → a simulated execution with specialist
delegation → mechanical sync → discovery review → `doctor` / `audit` → a dated,
signed acceptance report.

Each step is tagged:

- **[M] mechanical** — no LLM, no human judgement. Reproducible by
  `scripts/acceptance.sh`, which runs the `[M]` steps in this exact order and
  prints each step tag as it covers it.
- **[A] agent-driven** — a person runs a session (or drives an agent) and
  records the outcome by hand in the report.

`scripts/acceptance.sh` and this document must not drift. A task in the
`end-to-end-acceptance` change keeps them in step; if you change one, change the
other.

## Prerequisites

| Need | Why | Check |
| --- | --- | --- |
| `git` >= 2.30 | throwaway repo, commits, `git diff` assertions | `git --version` |
| `node` >= 18 | runs the installer (`bin/cli.js`) | `node --version` |
| `bash`, coreutils | the harness and `scripts/test` | — |
| `bd` (Beads) + `dolt` | real-backend run only ([A] + full [M]); the `--mechanical` subset stubs both | `bd version`, `dolt version` |
| An **isolated** Beads workspace | so acceptance Beads never mix with real work | run in a throwaway repo, or a dedicated `.beads` |
| `v1.1.1` pushed + tagged on `JoMe92/nogging` | the real `npx github:` install path (step 3) | `git ls-remote --tags` |

The mechanical subset (`scripts/acceptance.sh --mechanical`) needs only `git`,
`node`, `bash` and coreutils — it stubs `bd` and `dolt` and needs no backend and
no network. That subset also runs from `scripts/test` (via
`scripts/acceptance.test.sh`) and as the `acceptance` CI job.

## Procedure

### 1. Create a throwaway target repository — [M]

- **Prerequisite:** a writable temp directory.
- **Do:**
  ```bash
  target="$(mktemp -d)"
  git -C "$target" init -q
  git -C "$target" config user.email acceptance@example.invalid
  git -C "$target" config user.name "Nogging Acceptance"
  ```
  Leave `core.hooksPath` at its default so the Nogging boundary hooks bind
  once installed.
- **Expected:** an empty git repository on its initial branch, no tracked files.

### 2. Install Nogging from the local checkout — [M]

- **Prerequisite:** step 1; a Nogging checkout at `$root`.
- **Do:** `( cd "$target" && node "$root/bin/cli.js" init )`
  (the harness passes `--no-beads --no-systemd` in `--mechanical` mode; a full
  run installs the tracker too).
- **Expected:** `scripts/nogg`, `scripts/hooks/*`, `.nogging/config.json`,
  the `.agents/` skills and the `openspec/` scaffold are written; the git hooks
  are installed into `.git/hooks`; the command exits 0 and prints a readiness
  verdict (asserted in step 3).

### 3. Assert the readiness verdict — [M]

- **Prerequisite:** step 2.
- **Do:** read the last line of the installer output.
- **Expected:**
  - With the Beads backend present and provisioned: `Nogging is ready — run
    ./scripts/nogg plan-begin to start.` and `./scripts/nogg doctor`
    exits 0.
  - Without the backend (the `--mechanical` subset): `Nogging is installed but
    not ready: uninitialized tracker (run \`bd init\`)` — the uninitialized
    tracker is named as the only gap and the verdict does **not** claim the
    repository is ready.

### 4. Real-distribution install check — [A]

- **Prerequisite:** `v1.1.1` pushed and tagged on `JoMe92/nogging`; network
  access.
- **Do:** in a **second** throwaway repo,
  `npx github:JoMe92/nogging#v1.1.1 init`.
- **Expected:** the published package installs the same file set as step 2 and
  prints a readiness verdict. If the repository is not yet pushed/tagged, record
  this step **skipped** with that reason.

### 5. Open a planning session — [M]

- **Prerequisite:** step 2.
- **Do:** `( cd "$target" && ./scripts/nogg plan-begin )`
- **Expected:** `planning session lock acquired`; `.nogging/locks/planning.lock`
  exists.

### 6. Author or review the change — [A]

- **Prerequisite:** step 5.
- **Do:** in a real planning session a Planning Agent writes
  `proposal.md` / `design.md` / `tasks.md` / `specs/` for the change under test.
  For the acceptance procedure the **canned example change** at
  `scripts/fixtures/acceptance/` stands in for that work.
- **Expected:** a complete change with stable `TASK-…` IDs, ready to validate.

### 7. Drop in the canned example change — [M]

- **Prerequisite:** step 5.
- **Do:**
  ```bash
  cp -R "$root/scripts/fixtures/acceptance" \
        "$target/openspec/changes/acceptance-example"
  ```
- **Expected:** `openspec/changes/acceptance-example/` contains `proposal.md`,
  `design.md`, `tasks.md` (`TASK-ACCEPTX-001`, `TASK-ACCEPTX-002`) and
  `specs/acceptance-example/spec.md`.

### 8. Validate the change — [M]

- **Prerequisite:** step 7.
- **Do:** `( cd "$target" && ./scripts/nogg validate )`
- **Expected:** exits 0, reports no mapping / duplicate / task-parse problems.

### 9. Materialize the example's Beads — [M]

- **Prerequisite:** step 8.
- **Do:** `( cd "$target" && ./scripts/nogg materialize acceptance-example )`
- **Expected:** exactly one Bead is created per task in the example's
  `tasks.md` — one for `TASK-ACCEPTX-001` and one for `TASK-ACCEPTX-002`.
  Re-running `materialize` creates nothing.

### 10. Execute a task with specialist delegation — [A]

- **Prerequisite:** step 9; a convention-named branch (`<type>/<change-slug>`).
- **Do:** claim `TASK-ACCEPTX-001`'s Bead, delegate an isolated slice to one
  specialist, validate, then commit with a Conventional subject carrying the
  `[<bead-id>]` token; add a Bead note with the commit SHA and evidence.
- **Expected:** a commit on the convention branch whose subject matches the
  commit-message rule and names the Bead; the Bead has an evidence note.

### 11. Close the planning session — [M]

- **Prerequisite:** step 9 (step 10 when it is run).
- **Do:** `( cd "$target" && ./scripts/nogg plan-end )`.
- **Expected:** `planning session lock released`; the lock file is gone.
- **Why here:** the mechanical sync refuses to mirror while a planning session
  is open or while `HEAD` is on a protected branch (`sync-safety` / W5), so the
  runbook ends planning and moves onto a change branch before the sync
  round-trip — matching the operating model, where execution and the
  timer-driven sync run only after `plan-end`.

### 12. Simulate the closure and run the mechanical sync — [M]

- **Prerequisite:** step 11; a change branch checked out
  (`git checkout -b change/acceptance-example`).
- **Do:** close `TASK-ACCEPTX-001`'s Bead (`bd close <id>`, or the stub in
  `--mechanical`), then `( cd "$target" && ./scripts/nogg sync )`.
- **Expected:** the first sync flips **exactly one** `- [ ]` → `- [x]`
  (`TASK-ACCEPTX-001`) in the example's `tasks.md`, appends **exactly one**
  `execution-log.md` entry keyed to that closure, and makes one
  `chore(sync): mirror Beads execution evidence` commit.

### 13. Assert sync idempotency — [M]

- **Prerequisite:** step 12.
- **Do:** `( cd "$target" && ./scripts/nogg sync )` again.
- **Expected:** prints `sync: no changes`; `git diff` is empty; the
  execution-log entry count and the checked-task count are unchanged.

### 14. Review discoveries — [A]

- **Prerequisite:** step 9.
- **Do:** `( cd "$target" && ./scripts/nogg discoveries )`.
- **Expected:** every discovery filed during the run is listed (blocking first),
  or `no pending discoveries`. Record each discovery's Bead ID in the report.

### 15. `doctor` and `audit` are clean — [M]

- **Prerequisite:** step 12.
- **Do:** `( cd "$target" && ./scripts/nogg doctor )` then
  `( cd "$target" && ./scripts/nogg audit )`.
- **Expected:** both exit 0; `audit` writes a report under `.nogging/reports/`
  with no `FAIL` lines.

### 16. Tear down — [M]

- **Do:** `rm -rf "$target"` (and drop the throwaway Beads workspace).
- **Expected:** no acceptance artefacts remain outside `docs/acceptance/`.

### 17. Write the acceptance report — [A]

- **Prerequisite:** all steps above attempted.
- **Do:** copy `docs/acceptance-report-template.md` to
  `docs/acceptance/<YYYY-MM-DD>-<hostname>.md`, fill in the toolkit version and
  git SHA, a pass / fail / skipped result and a note for **every** step above,
  the deviations section, and every discovery Bead ID. Leave the
  `Signed-off-by:` line blank. Commit the report.
- **Expected:** a dated report exists under `docs/acceptance/` with a result for
  every step and a blank sign-off line.

### 18. Product Owner sign-off — [A]

- **Prerequisite:** step 17 committed.
- **Do:** a person reviews the report and completes the `Signed-off-by:` line in
  a **separate** commit.
- **Expected:** the change is considered accepted only once that signed commit
  exists. A green `acceptance` CI job is necessary but not sufficient — the
  `[A]` steps and this sign-off are the rest.

## What the mechanical harness covers

`scripts/acceptance.sh [--mechanical]` performs steps **1, 2, 3, 5, 7, 8, 9, 11,
12, 13, 15, 16** in this order and prints the `[M]` tag of each. It does not
perform the `[A]` steps (4, 6, 10, 14, 17, 18) — those are the human /
agent-driven remainder recorded in the report.
