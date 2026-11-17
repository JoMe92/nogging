## 1. The switch and the lanes (wave 1 and 2)

- [ ] TASK-CER-001 [standard] [~500 loc] The `ceremony.mode` switch is read in one place, and `nogg triage` picks a lane by fixed rules and records why.
  Per design Decisions 1 and 2 and the requirements on the switch, the triage rules and the effective lane. Read the `ceremony` block (mode, fast-lane file and line limits, lite minimum score) with the defaults and the fall-back of Decision 1, warn in `doctor` on a bad value, and add `nogg ceremony`, which prints the mode in effect, whether it is the default or configured, and the limits (the prompts of CER-005 and the hook of CER-003 rely on it). Implement the triage rules as a pure module with the facts passed in, and `nogg triage <description>` around it with the flags of Decision 2, the output naming mode, rules' lane, effective lane and every fired rule, `--json`, and `--bead <id>` appending the one triage line to the Bead's note. Register every new module in the installer's copy list and the package's file list. Document the `### ceremony` section in docs/configuration.md, `ceremony` and `triage` in docs/commands.md, and CHANGELOG.md [Unreleased].
  Tests: small (pure, facts passed in): each rule in order, "A security word forces the full spec", "A small bug is fast", "Missing facts never give the fast lane", the same input gives the same output, the effective lane per mode ("The default keeps the full spec"), block parsing with defaults, an unknown mode and a non-positive limit; medium (temporary repository, stub `bd` on PATH recording its argv): "An unknown mode falls back" through `doctor`, "The reasons land on the Bead", `nogg ceremony` for an unset and a configured block, `--json` output.
  Check: scripts/lib/ceremony_test.py; scripts/ceremony-cli.test.sh; scripts/doctor-ci-check.test.sh; scripts/manifest-doctor.test.sh. Branch feat/adaptive-ceremony.

- [ ] TASK-CER-002 [standard] [~600 loc] `nogg quick` creates a fast-lane Bead without an OpenSpec change, and a Lead can take it from kickoff to `task-done` on a `fast-` branch.
  Per design Decision 3 and the requirements on fast-lane Beads, the mapping layer and the fast-lane Lead. `nogg quick "<title>" --accept "<criterion>"` (3 to 5, the triage flags of CER-001) runs the triage and creates one Bead labelled `ceremony:fast` with the criteria in its acceptance field and the triage line in its note, or refuses as the requirement lists. `task-done` finishes a closed fast-lane Bead with nothing to tick, directly and through the sandbox broker (leave a clear place for CER-003's limit check before the success). The Lead kickoff for a fast-lane Bead names its title, criteria and the fast-lane rules instead of a task line. The branch rule accepts `<type>/fast-<bead-id>` only when the configured mode is not `always-full`, reading the configuration file without `bd`, and `worktree implement` allocates such a branch. Show that validate, materialize, sync, completion and archive readiness already accept the unmapped Bead, without changing them. Touch no dispatch, loop or session-wake code. Document the fast lane for operators in docs/operating-model.md (a short section) and docs/commands.md, and CHANGELOG.md [Unreleased].
  Tests: small the kickoff text for a fast-lane Bead ("The kickoff names the criteria"); medium (temporary repository, stub `bd` with a fast-lane fixture Bead): "No configuration changes nothing", "A fast-lane Bead is created", "Too few criteria are refused", "A lane other than fast is refused", "Validation and sync ignore the fast-lane Bead", "task-done finishes a fast-lane Bead" directly and through the broker, "A fast-lane branch needs the switch" in the branch rule and in `worktree implement`.
  Check: scripts/ceremony-quick.test.sh; scripts/task-done-broker.test.sh; scripts/bead-mapping.test.sh; scripts/hooks/branch-name.test.sh; scripts/session-kickoff-delivery.test.sh. Branch fix/adaptive-ceremony.

- [ ] TASK-CER-003 [standard] [~350 loc: below the range on purpose; one guard on the commit path, kept small so that its review covers all of it] A fast-lane Bead that outgrows 2 production files or the line limit is stopped with `needs-spec` by the commit hook, the staged test commands and `task-done`.
  Per design Decision 4 and the requirements on the escalation and on what it tells the Lead. One pure measurement takes the diff counts from the branch's merge point with develop plus staged changes, excludes test files by the test-integrity path rule, and compares with the configured limits. The commit hook, after its token check, asks `nogg` whether the token's Bead is fast-lane and over a limit when the mode is not `always-full`, and refuses with `needs-spec`, the counts, the limit and the Lead's next steps; without `bd` it warns and allows. `nogg test commit` and `nogg test bead` print the same finding for a fast-lane Bead; `task-done` refuses over a limit at the place CER-002 left. Document the escalation and the Lead's steps in docs/operating-model.md's fast-lane section and in docs/test-control.md, and CHANGELOG.md [Unreleased].
  Tests: small (pure, counts passed in): limits at 2 and 3 files and at the line limit, "Tests do not count", the refusal text ("The refusal names the steps"); medium (temporary repository with a develop branch and a fast-lane branch, stub `bd`): "A third production file is refused" through the hook, "No bd, no block in the hook", the hook is silent under `always-full` and for a Bead without `ceremony:fast`, the finding in `nogg test commit` and `nogg test bead`, "task-done is the backstop".
  Check: scripts/lib/ceremony_test.py; scripts/hooks/commit-msg.test.sh; scripts/ceremony-escalation.test.sh; scripts/task-done-broker.test.sh. Branch refactor/adaptive-ceremony.

## 2. Specs and the planner (wave 2)

- [ ] TASK-CER-004 [standard] [~450 loc] A lite spec can be scaffolded, passes `openspec validate --strict`, and `nogg validate` sends back one with fewer than 6 of its 8 completeness points.
  Per design Decision 5 and the requirements on lite specs and their score. Ship the lite template (a proposal with why, what and the eight sections with placeholders, the `.openspec.yaml` that marks the change lite and skips spec deltas, and a one-task `tasks.md`) and a scaffold command that writes it for a named change only while a planning session holds the lock and the mode is not `always-full`, and that checks the installed OpenSpec version. `nogg validate` recognises a lite change, refuses it under `always-full`, scores its eight sections against the placeholders, refuses under the configured minimum naming the missing points, and prints the score as a NOTE in `doctor`; full changes are not scored. Do not edit the `/plan` prompts (CER-005 does). Document the lite format in docs/ (where the change format is described) and the command in docs/commands.md, and CHANGELOG.md [Unreleased].
  Tests: small (pure, the proposal text passed in): "Five points are sent back", six points pass, "Placeholders do not count", a missing `## Why`; medium (temporary repository with OpenSpec available, or the test skips with its reason when OpenSpec is not installed): "A scaffolded lite change validates" with `openspec validate --strict` and `materialize` against a stub `bd`, "A lite change under the default is refused", the scaffold refuses without the planning lock and on an OpenSpec version it cannot support.
  Check: scripts/lib/ceremony_lite_test.py; scripts/ceremony-lite.test.sh; scripts/nogg-materialize.test.sh. Branch docs/adaptive-ceremony.

- [ ] TASK-CER-005 [standard] [~350 loc: below the range on purpose; mostly prompt text plus one note rule] When the switch is on, the `/plan` prompts start with triage and route by lane, task text describes behaviour, and `nogg validate` notes code identifiers in it.
  Per design Decision 6 and the requirements on the planner's routing and on the code-identifier note. Add one section to `.claude/commands/plan.md`, `.codex/prompts/plan.md`, `.pi/prompts/plan.md` and `.nogging/launch-prompts/planning.md`: it applies only when `nogg ceremony` reports a mode other than `always-full`; then run `nogg triage` first and route the fast lane to `nogg quick`, the lite lane to the lite scaffold and the full lane to today's flow; and write task text as behaviour and checks, never function names, internal identifiers or constants. Do not touch the Antigravity plan skill (feature freeze). Add the note rule of Decision 6 next to the existing task-format notes, active only off `always-full`, outside `Tests:` and `Check:`. Document the rule in docs/ next to the task-sizing guidance, and CHANGELOG.md [Unreleased].
  Tests: small (pure, task text passed in): "A function name is noted", "Paths and commands are not noted", an `UPPER_CASE` constant noted, configuration keys and flags not noted, nothing under `always-full`; medium: "The prompts carry the lane routing" in the shared-phrase planning-docs test for the three prompts and the launch prompt (the wording is the contract), installed prompts stay byte-equal to their sources, `nogg validate` still exits zero with a note.
  Check: scripts/lib/testing_tasks_test.py; scripts/planning-docs.test.sh; scripts/planning-kickoff.test.sh. Branch perf/adaptive-ceremony.

## 3. The context diet (wave 1)

- [ ] TASK-CER-006 [standard] [~650 loc: mostly Markdown moved from the agents block into skills, plus the installer choice] With the switch on, installs get a lean agents block under 150 lines, a pointer-only Claude block and on-demand skills; the default install is byte-identical.
  Per design Decision 7 and the requirements on the lean install and on the hard rules. Write the lean agents block (every hard rule of Decision 7 plus the skill list with paths and when to read each) and the pointer-only Claude block as templates, and the Nogging skills (Lead workflow, planning formats and lanes, sessions and orchestration, specialists, recovery) from one source, moving the text out of today's block without losing a rule. The installer's marker merge reads the target's `ceremony.mode` from its configuration file and picks the lean pair and installs the skills to `.claude/skills/` and `.agents/skills/` only when the mode is not `always-full`; under the default nothing changes. `doctor` warns when the installed block does not match the mode. Leave this repository's own `AGENTS.md` and `CLAUDE.md` untouched, and add nothing Antigravity-specific. Document the lean install in docs/installation.md and docs/configuration.md's ceremony section (create the section if CER-001 has not landed; keep both sides on rebase), and CHANGELOG.md [Unreleased].
  Tests: small the lean block's length under 150 lines and every named skill path exists in the source; medium (temporary target repositories): "The default install is unchanged" (byte-equal blocks, no new skill), "The lean install is short", `update` after a mode change switches the blocks and the skills both ways, "A mode change is noticed" in `doctor`, "The hard rules survive the diet" (the hard-rule phrases of today's block appear in the lean block or its skills; the write boundary, the Bead token and the test commands in the block itself).
  Check: scripts/planning-docs.test.sh; scripts/cli.test.sh; scripts/commands.test.sh; scripts/installer-output.test.sh; scripts/ceremony-install.test.sh. Branch test/adaptive-ceremony.

## 4. The gate (after the baseline)

- [ ] TASK-CER-007 [complex] [~300 loc: driver changes for arm D; the rest is the gate run on the run host] Arm D runs `ceremony.mode: adaptive` on the 10 small benchmark tickets, and the Phase 1 gate is evaluated against arm C by the preregistered criterion.
  Per design Decisions 8 and 9 and the requirement on arm D, with impact-benchmark design Decisions 6, 7, 19 and 22. Add `bench/arms/D.yaml` (arm C's agent, model, effort, timebox and credentials; the develop commit that integrates CER-001 to CER-006 as its Nogging ref; the switch `ceremony.mode: adaptive`). Make the bench driver write an arm's switches into the container's configuration after Nogging is initialised, launch the Lead on a fast-lane Bead when planning ends with one instead of a change, and record in the result line the lane chosen, each fast-lane Bead's production files and lines, and any `needs-spec` escalation (extend the result-line schema and `validate` with a test). Then on the x86_64 run host with the subscription logins: arm D on the 10 small drawn tickets, seeds 1 to 3, under the committed preregistration; `report` against arm C's full-run lines on the same tickets into `bench/reports/adaptive-ceremony-gate/`; the verdict (tokens comparison met, pass-rate comparison met or a tie, every fast-lane Bead within its limits or escalated) in the Bead note. Commit the results and the report. Change no default: a met gate is reported to the Orchestration Agent, and a missed one goes to the ablation report.
  Tests: small switch writing and the result-line lane fields in the schema; medium (stub `docker` and stub `nogg` from the bench suite): "The switch reaches the container", "A fast-lane outcome is driven to the end", "An unnoticed overflow fails the gate" in the gate evaluation; large (the real gate run on the run host).
  Check: uv run --project bench --extra dev pytest bench/tests/test_driver.py bench/tests/test_validate.py bench/tests/test_report.py; bench/nogg-bench validate bench/results. Branch chore/adaptive-ceremony-gate.

## Dependency contract

Explicit Beads edges, not task order, govern execution (`A <- B` means A depends on B):
002<-001; 003<-002; 004<-001; 005<-001; 007<-001; 007<-002; 007<-003; 007<-004; 007<-005;
007<-006; and across changes 007<-impact-benchmark BEN-014 and 007<-impact-benchmark BEN-010.

- 001 and 006 are independent and start at once.
- 002, 004 and 005 start when 001 is integrated, in parallel.
- 003 needs the fast-lane Bead and the `task-done` place of 002.
- 007 needs all six and the benchmark's baseline (BEN-014) and unattended arm C (BEN-010).

Branches are `<type>/adaptive-ceremony`, one type per task so that parallel worktrees never share a
branch: feat/ 001, fix/ 002, refactor/ 003, docs/ 004, perf/ 005, test/ 006, and
chore/adaptive-ceremony-gate 007. Before allocating a dependent worktree, verify that every
prerequisite execution commit is integrated into develop. A closed Bead alone is not enough.

## Execution contract

**Scope.** A task's first line is its Bead title. Its full slice is that line plus the indented
paragraph under it, the design Decisions it names, and the matching requirements in specs/. Read
those files explicitly; do not rely on skills loading by themselves.

**The switch.** Every behaviour of this change is inactive under `ceremony.mode: always-full`, the
default. A task whose change would alter a default behaviour, an installed file or an existing test
result under `always-full` records a blocking discovery instead.

**Pi Leads.** The Leads are Pi sessions, launched with `--agent pi --full-access` and without
`--tier`; write the tier reasoning to the Bead note anyway. Pi has no Task tool and no subagents:
do the specialist work (design check, review, tests) inline under the same rules, and add no
specialist `Co-authored-by` trailer. Run `./scripts/nogg recover` before anything else, allocate
the worktree with `./scripts/nogg worktree implement <bead> <branch>`, and integrate upstream only
with `./scripts/nogg worktree rebase`. Pi's floor blocks `curl`, `wget`, force-push, `reset --hard`
and `clean -f`; a refused step is a `blocked` signal, never a workaround.

**Work.** The Lead claims its one Bead and implements it only in its own allocated worktree, in
several commits within the configured commit range, each with the `[<id>]` token and the tests for
the code it changes. Feature freeze: no new feature in dispatch, loops, session wake or the
Antigravity support; a task that would need one records a blocking discovery.

**Testing.** Suites are offline: no real agent, Dolt server, shared tmux or herdr server, systemd
or network; `bd`, `gh` and `docker` are stubs on PATH, clocks are injected, nothing sleeps. A
medium test that needs OpenSpec skips with its reason when OpenSpec is missing. Test in stages:
`./scripts/nogg test changed` while working, `./scripts/nogg test commit` before each commit,
`./scripts/nogg test bead` once per Bead, plus the files the task's `Check:` names. The full suite
is CI's job. Run a long command as one blocking call with a timeout that covers it
(`./scripts/nogg run-quiet -- <command>`), never polled.

**Review.** CER-003 guards the commit path and CER-006 rewrites the instructions every consumer
session reads; each gets the Orchestration Agent's pull request review before merge, as no
`code-reviewer` subagent exists under Pi.

**Closing.** Push the branch and open the pull request against develop. After CI is green, run
`bd close`, then `./scripts/nogg task-done <id>`, and append every commit SHA and the evidence to
the Bead. Signal `done "PR #<n> open"` or `blocked "<why>"` at the end of the run.

**Limits.**
- Agents never hand-edit OpenSpec.
- Discoveries carry the discovery label and prose.
- Prompts, fixtures and docs contain no email address, no real token and no credential.
- This repository's own `AGENTS.md`, `CLAUDE.md` and `.nogging/config.json` mode stay unchanged.
- Nobody signs human acceptance.
