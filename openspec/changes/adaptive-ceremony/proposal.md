## Why

Nogging v3.6.0 runs the full ceremony for every change: a full OpenSpec change, one Bead, one
session, one worktree, one pull request, and every session reads several hundred lines of fixed
instructions. The roadmap (Rev 16, Phase 1) wants the ceremony to follow the task: small tasks run
without an OpenSpec change, mid-sized ones with a short spec, and every session reads at most 150
lines of fixed instructions. Uvik's benchmark found that specs help features and not small
tickets, and that a spec with at least 6 of 8 completeness points merged far more often. The
expected effect in our benchmark: fewer tokens and less time on small tickets at the same pass
rate.

Everything lands behind one switch, `ceremony.mode`, whose default `always-full` keeps today's
behaviour. The benchmark's baseline arm C is pinned to v3.6.0, so this change cannot move the
baseline. On 2026-11-17 the Product Owner, through the Orchestration Agent, allowed the
implementation to start before the Phase 0 baseline report exists; the roadmap's "done when"
stays the gate for switching the mode on.

## What Changes

- **A switch, `ceremony.mode`** in `.nogging/config.json`: `always-full` (today, the default),
  `adaptive` and `always-fast`. Unknown values fall back to `always-full` with a `doctor` warning.
- **Three lanes and a deterministic triage.** `nogg triage <description>` applies fixed rules to
  the description and the facts the caller states, picks the fast lane, a lite spec or a full spec,
  prints the reasons, and on request writes them to a Bead note. The mode decides whether the
  chosen lane takes effect.
- **The fast lane.** `nogg quick "<title>" --accept "..."` (3 to 5 criteria) creates a Bead with no
  OpenSpec change. Validation, materialisation, sync and `task-done` accept such Beads; a Lead
  gets a kickoff that names the criteria, and its branch is `<type>/fast-<bead-id>`.
- **Escalation.** A fast-lane Bead that grows past 2 production files or the line limit is stopped
  with `needs-spec`: by the commit hook where it runs, by the staged test commands, and by
  `task-done`.
- **Lite specs.** A scaffold writes a lite change (a proposal with what, why and scenarios, and a
  minimal task list) that passes `openspec validate --strict`; `nogg validate` scores its eight
  completeness points and sends back a spec under 6.
- **A planner rule.** In `adaptive` and `always-fast`, the `/plan` prompts for Claude Code, Codex and
  Pi start with triage and route by lane, and task text describes behaviour and checks, not
  function names or constants; `nogg validate` notes code identifiers in task text.
- **A context diet.** With the mode off `always-full`, the installer writes a lean agents block of
  under 150 lines and a pointer-only Claude block, and moves roles, flows and spec formats into
  skills read on demand.
- **The Phase 1 gate.** Arm D runs `ceremony.mode: adaptive` on the benchmark's 10 small tickets
  and is compared with arm C by the criterion preregistered in `bench/PREREGISTRATION.md`.

## Done when (the roadmap's gate for switching the mode on)

- Arm D with `ceremony.mode: adaptive` uses measurably fewer tokens than arm C on the 10 small
  tickets and does not pass less often, by the preregistered criterion.
- No fast-lane run changed more than 2 production files without a `needs-spec` escalation.
- With `ceremony.mode` unset or `always-full`, every existing behaviour, installed file and test is
  unchanged.

The shipped default stays `always-full` in this change. Changing it, or switching this
repository's own mode, is a later Product Owner decision taken in a planning session.

## Capabilities

### New Capabilities

- `adaptive-ceremony`: the ceremony switch, triage, the fast lane and its escalation, lite specs
  and their completeness check, the planner rule, the lean instructions, and the Phase 1 gate arm.

### Modified Capabilities

None directly. Branch naming, `task-done`, the installer and `nogg validate` gain behaviour only
when the switch is off its default; that behaviour is specified in `adaptive-ceremony`.

## Impact

- `scripts/nogg` and new pure modules under `scripts/lib/`, `scripts/check-branch-name`,
  `scripts/hooks/commit-msg`, the installer under `bin/lib/`, new templates and skills, the
  `/plan` prompts of Claude Code, Codex and Pi and the planning launch prompt, `docs/`, and
  `bench/` for arm D.
- Not touched: dispatch, loops, session wake and the Antigravity support (feature freeze in
  `AGENTS.md`), this repository's own `AGENTS.md` and `CLAUDE.md`, and the shipped default.
