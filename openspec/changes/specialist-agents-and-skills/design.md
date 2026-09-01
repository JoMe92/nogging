# Design

## Context

SpecForge splits a session into two personas of the top-level Claude session —
the Lead Agent (Main Worker, default behaviour from `CLAUDE.md`, works Beads and
reads OpenSpec) and the Planning Agent (entered via `/plan`, writes OpenSpec,
materializes Beads). Neither is a subagent; both talk to the user directly. The
concept conversation (sections 5 and 9) is explicit about this and about the
six specialists being the only real subagents: `.claude/agents/*.md` files
invoked through the Task tool.

Two mechanical guarantees the specialists rely on already exist:

- The `PreToolUse` guard (`scripts/hooks/pre-tool-use-openspec-guard`, wired in
  `.claude/settings.json`) blocks any Edit/Write under `openspec/` unless the
  planning lock is held, so a specialist physically cannot edit OpenSpec.
- `scripts/specforge sync()` writes `execution-log.md` entries from closed
  Beads, so a specialist never needs to record execution evidence in a spec.

What is missing is the roster itself and the delegation contract. `AGENTS.md`
already states the execution hard rules (rules 1–4: no `openspec/` edits, work a
claimed Bead, commit with a Bead ID and evidence note, record discoveries with
the `discovery` label and a prose note). The specialist definitions inherit
those rules; they narrow them further because a specialist does not own the
Bead.

Section 7 describes how the Lead Agent briefs a specialist: `bd show <id>`
returns the Bead's `openspec:task:<TASK-ID>` label, and the Lead Agent reads
only the referenced slice of `tasks.md` / `specs/` rather than the whole
`proposal.md` / `design.md`. `scripts/specforge materialize` currently sets both
`openspec:change:<name>` and `openspec:task:<TASK-ID>` labels on every created
Bead. That behaviour is load-bearing and is promoted here to a spec requirement.

## Goals / Non-goals

- Goal: the six specialists exist as invocable `.claude/agents/*.md` agents,
  each with one responsibility and a tool set scoped to it.
- Goal: a specialist cannot step outside execution boundaries — no `openspec/`
  writes, no Bead claim/close, no commit, one Bead at a time.
- Goal: a plan-relevant finding a specialist makes reaches the Lead Agent, who
  records it; the specialist does not label the Bead or abandon the task on its
  own initiative.
- Goal: `CLAUDE.md` states the Lead Agent delegation model; `AGENTS.md` points
  to it for non-Claude tools without duplicating content.
- Goal: materialized Beads carry a resolvable `openspec:task:<id>` label.
- Non-goal: the `PreToolUse` guard and `execution-log.md` generation (both done).
- Non-goal: defining `/plan`, `/discovery-review` or the Planning Agent persona
  (owned by `planning-and-discovery-commands`).
- Non-goal: shipping `.claude/agents/` through the installer (a follow-up to
  `specforge-installer`).
- Non-goal: new skills infrastructure beyond the existing `.agents/skills/` set;
  changing the Beads workflow block in `CLAUDE.md`.
- Non-goal: writing the full verbatim agent prompt text into the spec — the
  spec stays behavioural, the task files carry the wording.

## Decisions

### The six specialists and their scopes

| Agent | Responsibility | Writes source? | Typical tools |
| --- | --- | --- | --- |
| `architect` | Answer an architecture/design question for one Bead or, when pulled in by the Planning Agent, one change; produce analysis and a recommendation | no | read, search, run read-only commands |
| `ui-ux-designer` | Turn a UI-facing Bead into an interaction/layout/state specification the frontend engineer can implement | no (specs/notes only) | read, search |
| `backend-engineer` | Implement the server/data/CLI side of one claimed Bead | yes | read, search, edit, run build/tests |
| `frontend-engineer` | Implement the client/UI side of one claimed Bead | yes | read, search, edit, run build/tests |
| `code-reviewer` | Review the diff for one claimed Bead against its task slice and report findings ranked by severity | no | read, search, git diff |
| `test-runner` | Run the relevant tests for one claimed Bead, add missing coverage, report pass/fail with output | yes (tests) | read, search, edit, run tests |

`architect` is available to both the Planning Agent (architecture questions
during authoring) and the Lead Agent. The other five are Lead-Agent-only.

### Boundary rules every specialist definition repeats

1. Never create, edit or delete anything under `openspec/` — read-only, and the
   `PreToolUse` guard enforces it anyway.
2. Operate on exactly the one Bead ID the Lead Agent names in the delegation
   prompt. Do not run `bd ready`, do not pick up other work, do not read or act
   on other Beads except to understand a stated dependency.
3. Never run `bd update --claim`, `bd close`, `bd update --status`, or any
   `git commit` / `git push`. Claiming, closing, committing and evidence notes
   are Lead Agent actions.
4. Return a structured result to the Lead Agent: what was done, which files
   changed, how it was validated, and anything unresolved.
5. On a plan-relevant finding (the task cannot be done as specified, or a
   decision is missing), stop and report it to the Lead Agent as a candidate
   discovery with the evidence. Do not add the `discovery` label yourself and
   do not silently deviate from the task.

### Lead Agent delegation model in `CLAUDE.md`

A new section states: after claiming a Bead and reading its task slice, the Lead
Agent decides to implement directly or delegate to one specialist via the Task
tool; the Lead Agent passes the Bead ID, the task slice, and the relevant spec
excerpt into the delegation prompt; on the specialist's return the Lead Agent
validates, records the evidence note, commits with the `[<ID>]` token, and
closes the Bead. OpenSpec stays read-only for the Lead Agent. This section sits
alongside — not inside — the managed Beads block, which is left unchanged.

### `AGENTS.md` stays a cross-tool pointer

`AGENTS.md` gains one short subsection: "Specialist delegation (Claude Code)"
pointing at `.claude/agents/` and the `CLAUDE.md` delegation section, and
stating the tool-neutral rule (isolated implementation may be delegated;
claiming/closing/committing stay with the Main Worker). No definitions are
copied in, consistent with the existing style of `AGENTS.md`.

### Task-reference label is a contract

Promote the current `scripts/specforge materialize` behaviour to a requirement:
every Bead it creates carries `openspec:change:<name>` and
`openspec:task:<TASK-ID>`, and `openspec:task:<TASK-ID>` resolves to exactly one
`- [ ] TASK-...` line in that change's `tasks.md`. A regression check in
`scripts/specforge.test.sh` (or a sibling) asserts both labels are set and the
task label resolves. `scripts/specforge validate` already flags a Bead that
maps a missing task; this adds the positive assertion at materialize time.

## Risks / open questions

- Tool-scoping syntax for `.claude/agents/*.md` frontmatter may evolve; the
  definitions should express intent (advisory vs implementing) in prose too, so
  they degrade gracefully if a field is renamed.
- The installer (`specforge-installer`) does not ship `.claude/agents/` yet.
  Until its manifest is extended, a repo installed from the package has the
  delegation text in `CLAUDE.md` but no specialist files. Flagged as a
  dependency; the follow-up is a one-line manifest addition.
- `ui-ux-designer` and `architect` produce specifications but must not write
  them into `openspec/`; they hand text back to the Lead Agent, who keeps it in
  the Bead or in code comments. This is a deliberate constraint of the
  read-only-OpenSpec rule and should be called out in both definitions.
- Over-delegation risk: a Lead Agent that delegates trivially loses context.
  The `CLAUDE.md` section should frame delegation as for genuinely isolated work
  (a self-contained backend handler, a review pass), not a default.
