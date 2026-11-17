## Context

Roadmap Rev 16, Phase 1 (`adaptive-ceremony`), kept outside the repository. Its three lanes:

| Lane | When | What is produced |
| --- | --- | --- |
| Fast lane | a bug fix with a reproducing test, a refactoring with green tests, a test ticket, a constant or configuration change; expected at most 2 files | one Bead with 3 to 5 acceptance criteria, no OpenSpec change |
| Lite spec | 3 or more files, a clear goal | a short proposal with what, why and scenarios |
| Full spec | new features, data pipelines, high ambiguity, public interfaces, security | today's full change |

Its tasks CER-001 to CER-006 are taken over with their roadmap scope. Its gate: arm D with
`ceremony.mode=adaptive` uses measurably fewer tokens than arm C on the 10 small tickets and does
not pass less often, and no fast-lane run changed more than 2 files unnoticed.

Constraints:

- Everything sits behind `ceremony.mode`; the default `always-full` keeps every behaviour, every
  installed file and every test result of today.
- The benchmark's arm C is pinned to Nogging v3.6.0 (`bench/arms/C.yaml`), so nothing on `develop`
  can move the baseline.
- On 2026-11-17 the Product Owner, through the Orchestration Agent, allowed the implementation to
  start before the Phase 0 baseline report, because everything is behind the switch. The roadmap's
  "done when" remains the gate for switching the mode on (Decision 9).
- The feature freeze in `AGENTS.md` holds: no new features in dispatch, loops, session wake or the
  Antigravity support.
- The Leads of this change are Pi sessions without subagents (Decision 11).

## Goals / Non-Goals

**Goals**

- A small task can go from a one-line description to a merged pull request without an OpenSpec
  change, with the same evidence in Git and Beads as any Bead.
- A fast-lane task cannot silently grow into a feature.
- A mid-sized task gets a short spec that is checked for completeness before it is executed.
- With the mode on, a session reads under 150 lines of fixed instructions and loads the rest on
  demand.
- The gate is measured with the same benchmark and preregistration as the baseline.

**Non-Goals**

- Changing the shipped default or this repository's own mode, `AGENTS.md` or `CLAUDE.md`.
- Bundling Beads into work units (Phase 2), an evaluator or merge gate (Phase 3), or removing the
  sync timer (Phase 4).
- Any fast-lane awareness in dispatch, loops or session wake, and any change to the Antigravity
  plan skill or Antigravity guide (feature freeze).
- CI parity for the escalation check: agents cannot edit `.github/workflows/` (the token lacks the
  `workflow` scope) and CI has no `bd`.

## Decisions

### Decision 1: One switch with three values

`.nogging/config.json` gains a `ceremony` block:

```json
{ "ceremony": { "mode": "always-full",
                "fast_lane": { "max_files": 2, "max_lines": 200 },
                "lite": { "min_score": 6 } } }
```

| Mode | Triage | `nogg quick` | Escalation | Lite specs | Planner rule and hint | Installed instructions |
| --- | --- | --- | --- | --- | --- | --- |
| `always-full` (default) | reports the rules' lane, effective lane is full | refuses | inactive | refused by `validate` | inactive | today's blocks, byte-identical |
| `adaptive` | the rules' lane takes effect | allowed for a fast lane | active | allowed and scored | active | lean blocks and skills |
| `always-fast` | every description is fast lane | allowed | active | allowed and scored | active | lean blocks and skills |

`always-fast` exists for the benchmark's ablations; the escalation still catches a task that
outgrows the lane. Only one accessor reads the block, modelled on the `task_sizing` parser
(`scripts/nogg` around line 2281): it returns the mode, the limits and the problems; an unknown mode
or a non-positive limit falls back to the default and `doctor` prints a WARN, as it does for a bad
`task_sizing` (around line 11398). `nogg ceremony` prints the mode in effect, whether it is the default or
configured, and the limits; the planner prompts (Decision 6) and the hook (Decision 4) ask it
instead of parsing the file. The key stays out of `templates/nogging-config.json`, so an
install that never sets it needs nothing. `docs/configuration.md` gets a `### ceremony` section.
The lanes, rules and limits live in a pure module under `scripts/lib/` with the facts passed in.

### Decision 2: Triage is a pure function of the description and stated facts

`nogg triage <description> [--kind bug|refactor|test|config|feature|pipeline] [--files <n>]
[--public-interface] [--security] [--unclear] [--bead <id>] [--json]`. The rules, in order:

1. **Full** when `--kind feature` or `pipeline`, `--public-interface`, `--security` or `--unclear`
   is given, or the description contains a full-spec trigger word from the module's fixed list
   (for example security, credential, token, permission, authentication, migration, schema, public
   API, pipeline, new command).
2. **Lite** when `--files` is 3 or more.
3. **Fast** when `--kind` is `bug`, `refactor`, `test` or `config` and `--files` is 1 or 2.
4. **Lite** otherwise: a missing kind or file estimate never yields the fast lane.

The rules' lane is then mapped through the mode (Decision 1) to the effective lane. The output names
the mode, the rules' lane, the effective lane and every rule that fired; `--json` prints the same as
an object. `--bead <id>` appends `triage: <effective lane> (mode <mode>; rules: <lane>):
<reasons>` to that Bead's note. The same input always gives the same output; nothing reads the
network, the clock or a model.

### Decision 3: A fast-lane Bead is an unmapped Bead with one label

`nogg quick "<title>" --accept "<criterion>" … [triage flags]` runs the triage of Decision 2 and
refuses when the mode is `always-full`, when the effective lane is not fast (naming the lane and
the next step: a lite or full planning session), or when there are fewer than 3 or more than 5
criteria. It creates one Bead with the label `ceremony:fast`, the criteria in the Bead's acceptance
field, and the triage line in its note, and prints the Bead ID. It never adds an `openspec:` label:
an `openspec:change:` label without a task label is an `incomplete-label-pair` defect today.

The mapping layer already treats a Bead without `openspec:` labels as unmapped and valid
(`classify_mapping`, `scripts/nogg` around line 1240): `validate`, `materialize`, `sync`, the
completion check and the archive readiness skip it. Two places refuse it today and get a fast-lane
branch:

- `task-done` errors on a Bead without a task (around line 1069), and the sandbox broker reaches the
  same code; for a `ceremony:fast` Bead it ticks nothing and exits 0 after the escalation check of
  Decision 4.
- The Lead kickoff message needs a task line (around line 9197); for a `ceremony:fast` Bead it names
  the title, the acceptance criteria and the fast-lane rules (a red test first for a bug, the file
  and line limits, `needs-spec` on overflow).

A fast-lane branch is `<type>/fast-<bead-id>` (for example `fix/fast-spec-ab12`). The branch rule
accepts that form only when the mode is not `always-full`; it reads the mode from
`.nogging/config.json` and needs no `bd`, so CI applies the same rule. `worktree implement` accepts
it for a `ceremony:fast` Bead. The evidence is the same as for every Bead: each commit carries the
`[<id>]` token and the Bead note lists every SHA. There is no execution-log entry, because there is
no change to mirror into.

### Decision 4: Escalation measures the whole Bead branch

The limits (Decision 1) count production files and changed production lines, cumulatively from the
branch's merge point with `develop`, plus what is staged. Test files are recognised by the same
test-path rule the test-integrity check uses and do not count, so a bug fix with its reproducing
test still fits. The measurement is one pure function with the diff counts passed in; it runs in
three places:

- **The commit hook**, after its token check, when the mode is not `always-full` and the token's
  Bead carries `ceremony:fast`: over a limit, the commit is refused with `needs-spec`, the counts,
  the limit and the steps of the next paragraph. When `bd` cannot be reached the hook warns and
  allows the commit; the later points catch it.
- **The staged test commands**, `nogg test commit` and `nogg test bead`, print the same finding
  for a fast-lane Bead.
- **`task-done`** refuses to finish a fast-lane Bead over a limit. This is the backstop, because
  this repository's hooks path points at `.beads/hooks` and the Nogging hooks do not run here.

On a refusal the Lead stops implementing, adds the labels `needs-spec` and `discovery` with a prose
note (what grew, the counts), sets the Bead `blocked`, and signals `blocked "needs-spec"`. A
planning session then triages the task again as lite or full. CI has no parity (Non-Goals).

### Decision 5: A lite spec is a proposal plus two small files

A scaffold command writes `openspec/changes/<name>/` from a shipped template, during a planning
session only:

- `proposal.md` with `## Why`, `## What` and the eight completeness sections `## Goal`,
  `## Non-goals`, `## Acceptance criteria` (as WHEN/THEN scenarios), `## Edge cases`,
  `## Constraints`, `## Affected areas`, `## Validation`, `## Risks`;
- `.openspec.yaml` with `schema: spec-driven`, `skip_specs: true` and `x-nogging-ceremony: lite`;
  OpenSpec 1.17.0 then accepts a change with no spec deltas under `--strict`, and the `x-` prefix is
  the form strict validation tolerates for a foreign key;
- `tasks.md` with one or a few task lines, because `materialize` needs a task list.

`nogg validate` recognises a lite change by the `x-nogging-ceremony: lite` key. It refuses a lite
change while the mode is `always-full`. Otherwise it scores the eight sections: a section counts
when it holds at least one line that is not empty and not the template's placeholder. A score under
`ceremony.lite.min_score` (default 6) is a refusal that names the missing points: the spec goes back
to the planner. `doctor` prints the same as a NOTE. A full change is not scored. `skip_specs` and
`x-` keys are verified on OpenSpec 1.17.0 only, while `doctor`'s stated baseline is 1.11.x; the
scaffold and `validate` therefore check the installed OpenSpec version and refuse a lite change
with the version they need.

### Decision 6: The planner routes by lane and writes behaviour, not code

When the mode is not `always-full`, the `/plan` prompts start with triage: fast lane → `nogg
quick`, lite → the lite scaffold, full → today's flow. Task text in `tasks.md` and in lite
proposals describes behaviour and how it is checked, not function names, internal identifiers or
constants; file paths, command lines, flags and configuration keys stay allowed, because they are
what a user sees. The section is written so that it says it applies only when `nogg` reports a mode
other than `always-full`; the prompts are installed byte-equal to their sources, so this keeps the
default behaviour unchanged.

Files: `.claude/commands/plan.md`, `.codex/prompts/plan.md`, `.pi/prompts/plan.md` and
`.nogging/launch-prompts/planning.md`. Not `templates/antigravity/skills/nogging-plan/SKILL.md`
(feature freeze); the shared-phrase test already exempts the Antigravity skill. CER-005 owns every
edit to these prompts, including the lane routing that names CER-002's and CER-004's commands, so
no other task edits them.

The hint: `nogg validate` prints a NOTE (never a refusal) per task line whose text, outside the
`Check:` and `Tests:` fields, contains a code identifier: a call such as `parse()`, a
`snake_case` or `CamelCase` name in backticks, or an `UPPER_CASE` constant. Paths (a `/` or a file
extension), command lines, flags and dotted lower-case configuration keys are not flagged. It runs
next to the existing task-format notes (`scripts/lib/testing_tasks.py`) and only when the mode is
not `always-full`.

### Decision 7: The context diet is an installer choice

This repository's own `AGENTS.md` (360 lines) and `CLAUDE.md` (172 lines) carry no managed
markers and are not shrunk in this change: shrinking them would change the instructions of the
Leads building it, with the switch off. The diet is what consumer installs get when the mode is on:

- `templates/agents-block-lean.md`, under 150 lines: the hard rules (the `openspec/` write
  boundary, a claimed Bead only, commits with the `[<id>]` token in the configured range, the
  staged test commands and the test-integrity rule, discoveries with the label and a prose note,
  the progress breadcrumb, the end-of-run signal, `recover` before `bd ready`), the roles in one
  line each, and a list of skills with their paths and when to read each.
- `templates/claude-block-lean.md`: a pointer to `AGENTS.md` only.
- Skills from one source, installed to `.claude/skills/nogging-<name>/SKILL.md` and
  `.agents/skills/nogging-<name>/SKILL.md`: the Lead workflow (claim, worktree, test stages, close
  order, evidence), planning (lanes, the lite and full formats, task sizing, `Tests:` and `Check:`),
  sessions and orchestration, specialists and delegation, and recovery. Their text moves out of
  today's block; nothing is lost, and a test compares the hard-rule phrases.
- The installer's marker merge picks the lean pair when the target's `ceremony.mode` is not
  `always-full`, which it can read because the scaffold is written before the merges; the skills
  are installed only then. A mode change takes effect at the next `nogg update`; `doctor` warns when
  the installed block does not match the mode.
- Agents that do not load skills automatically (Pi; skill loading there is not verified) read them
  by the path the lean block names.

The `.agents/skills/` directory is also where Antigravity finds skills. Shipping generic Nogging
skill files there changes no Antigravity code, guide, guard or launch behaviour, so it is not an
Antigravity feature under the freeze; nothing Antigravity-specific is added. The bd-owned Beads
block in a consumer's `CLAUDE.md` is outside Nogging's control and is not counted.

### Decision 8: Arm D and the gate measurement

CER-007 adds `bench/arms/D.yaml`: kind `nogging`, the same agent, model, effort, timebox and
credentials as arm C, `nogging_ref` set to the `develop` commit that integrates CER-001 to CER-006,
and `switches: {ceremony.mode: adaptive}`. The bench driver writes the switches into the container's
`.nogging/config.json` after initialising Nogging, and handles the fast-lane outcome: when the
planning session ends with a `ceremony:fast` Bead instead of a change, it launches the Lead on that
Bead. The result line records, for a `nogging` arm, the lane triage chose, each fast-lane Bead's
production files and lines, and any `needs-spec` escalation.

Arm D runs on the 10 small tickets with seeds 1 to 3, under the committed preregistration whose
thresholds block already carries this gate (impact-benchmark BEN-006), and `report` compares it
with arm C's full-run lines on the same tickets. The gate holds when the preregistered tokens
comparison is met, the pass-rate comparison is met or a tie, and every fast-lane Bead either stayed
within its limits or was escalated. The verdict and the report under
`bench/reports/adaptive-ceremony-gate/` are committed. A missed gate keeps the default and goes to
the ablation report, as the roadmap says.

### Decision 9: Order relative to the benchmark

The implementation (CER-001 to CER-006) starts now, in parallel with Phase 0, because it is
switched off by default and arm C is pinned. Only CER-007 waits for the baseline: it needs the
committed preregistration, the drawn tickets, arm C's full run (impact-benchmark BEN-014) and arm
C's unattended container (BEN-010). These edges are explicit Beads dependencies across the two
changes.

### Decision 10: Waves and branches

```text
CER-001 switch + triage ──┬── CER-002 fast lane ── CER-003 escalation ──┐
                          ├── CER-004 lite spec ────────────────────────┤
                          └── CER-005 planner rule ─────────────────────┼── CER-007 gate (+ BEN-010, BEN-014)
CER-006 context diet ───────────────────────────────────────────────────┘
```

- Wave 1, in parallel: CER-001 and CER-006. The installer reads the target's configuration file
  itself, so the diet needs no part of CER-001.
- Wave 2, in parallel: CER-002, CER-004 and CER-005, all on CER-001's switch and triage.
- Wave 3: CER-003 needs the fast-lane Bead and the `task-done` branch of CER-002.
- Wave 4: CER-007 needs all six and the baseline.

CER-005 names CER-002's and CER-004's commands in the prompts but does not need them to exist:
its prompt test checks wording, and the commands' own tests are in their tasks. Shared hot spots,
where a later Lead rebases with `nogg worktree rebase` and keeps both sides: the command parser in
`scripts/nogg` (CER-001, 002, 003, 004), the `doctor` diagnostics block (CER-001, 004, 005), the
copy list in `bin/lib/manifest.js` and the `files` list in `package.json` for every new module, and
`docs/configuration.md` and `docs/commands.md`. Branches are `<type>/adaptive-ceremony`, one type
per task: feat/ 001, fix/ 002, refactor/ 003, docs/ 004, perf/ 005, test/ 006,
chore/adaptive-ceremony-gate 007.

### Decision 11: Pi Leads, no subagents

The Product Owner wants Pi for the development Leads of roadmap work (Beads memory
`dev-agent-pi`, 2026-11-17): `session launch --agent pi --full-access`, without `--tier`, with the
tier reasoning written to the Bead note anyway. Pi has no Task tool, so the Lead does specialist
work inline under the same rules and adds no specialist `Co-authored-by` trailer; a separate
`session launch --agent pi --role specialist:<type>` is the only delegation path and is not needed
here. Pi does not auto-load skills or the OpenSpec skill files reliably, so the kickoff points to
the files to read. Pi's floor blocks `curl`, `wget`, force-push, `reset --hard` and `clean -f`. A
review pass that a Claude Lead would delegate to `code-reviewer` is the Orchestration Agent's pull
request review here.

## Risks / Trade-offs

- **The triage misjudges a large task as fast.** → The escalation of Decision 4 at three points,
  with `task-done` as the backstop; missing facts never give the fast lane.
- **The hook does not run where `core.hooksPath` points elsewhere**, including this repository. →
  `nogg test commit|bead` and `task-done` carry the same check; the gate counts escalations.
- **The lean block drops a rule an agent needed.** → The lean block keeps every hard rule, a test
  compares the hard-rule phrases of both blocks, and the skills carry the rest verbatim.
- **Prompt text under the default.** The planner section is present but says it is inactive under
  `always-full`. → Accepted: installed prompts stay byte-equal to their source; a mode-selected
  prompt fragment would be a second installer path for little gain.
- **OpenSpec version spread.** → The lite scaffold and `validate` check the version (Decision 5).
- **Six parallel Leads in one monolith.** → Shared spots listed (Decision 10); each task names the
  suites it affects; `nogg worktree rebase` for upstream integration.

## Migration Plan

Nothing migrates while the mode is `always-full`. Switching a repository to `adaptive` is: set the
key, run `nogg update` (lean blocks and skills), `doctor`. Switching back restores today's blocks
at the next `update`; fast-lane Beads already closed stay valid unmapped Beads.

## Open Questions

None for this change. Whether and when to change the shipped default, and whether this repository
runs `adaptive` itself, are Product Owner decisions after the gate.
