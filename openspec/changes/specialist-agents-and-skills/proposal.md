# Add specialist subagents and the Lead Agent delegation model

## Why

The concept conversation of 2026-08-31 (`docs/source/konversation-export.md`,
sections 5, 7 and 9) fixed the execution side of SpecForge as a Lead Agent
(Main Worker) that claims Beads and delegates isolated implementation work to
six specialist subagents invoked through the Task tool. Today the repository
carries none of that structure:

- `docs/operating-model.md` names "Main Worker" and "Specialists" in one line
  each. There is no definition of what a specialist is, what it may touch, or
  how the Lead Agent hands work to it.
- There are no `.claude/agents/*.md` files, so the six specialists
  (`architect`, `ui-ux-designer`, `backend-engineer`, `frontend-engineer`,
  `code-reviewer`, `test-runner`) do not exist as invocable agents.
- `CLAUDE.md` describes Beads task-tracking and git profiles but never states
  that the Lead Agent delegates implementation, nor that claiming, closing and
  committing stay Lead-Agent actions.
- `AGENTS.md` holds the execution hard rules but points at nothing for the
  specialist roster, so a non-Claude tool has no path to the same model.
- The Lead Agent's targeted-context path (section 7) depends on a materialized
  Bead exposing an `openspec:task:<id>` label. `scripts/specforge materialize`
  already sets that label, but nothing records it as a contract, so a future
  change could drop it and silently break specialist briefing.

The write-boundary `PreToolUse` guard and the `execution-log.md` generation in
`scripts/specforge sync()` already exist; this change does not touch them.

## What changes

- **Six specialist agent definitions:** add
  `.claude/agents/{architect,ui-ux-designer,backend-engineer,frontend-engineer,code-reviewer,test-runner}.md`,
  each with one responsibility, a scoped tool set, and the SpecForge execution
  hard rules. `architect` and `code-reviewer` are advisory (no source writes);
  `backend-engineer` and `frontend-engineer` implement against a claimed Bead;
  `test-runner` runs and writes tests; `code-reviewer` reports findings.
- **Execution boundary for specialists:** a specialist never edits `openspec/`,
  operates only on the single already-claimed Bead the Lead Agent passes in,
  never claims/closes a Bead or commits, and reports its result to the Lead
  Agent.
- **Discoveries flow up:** a specialist that hits a plan-relevant finding
  reports it to the Lead Agent rather than labelling the Bead or changing
  course itself; the Lead Agent records the discovery per `AGENTS.md`.
- **Lead Agent delegation model in `CLAUDE.md`:** the Lead Agent may delegate
  isolated implementation to a specialist through the Task tool; claiming,
  closing, committing and OpenSpec reads stay with the Lead Agent, and OpenSpec
  stays read-only for all execution roles.
- **Cross-tool pointer in `AGENTS.md`:** `AGENTS.md` references `.claude/agents/`
  and the delegation model without duplicating the definitions.
- **Task-reference contract:** every materialized Bead SHALL carry a resolvable
  `openspec:task:<id>` label so the Lead Agent can read only the referenced
  slice of `tasks.md` / `specs/` when briefing a specialist.

## Impact

- Affected specs: `specialist-agents` (new capability).
- Affected code (implementation deferred to execution): new
  `.claude/agents/{architect,ui-ux-designer,backend-engineer,frontend-engineer,code-reviewer,test-runner}.md`;
  modified `CLAUDE.md` (Lead Agent delegation section), `AGENTS.md` (pointer to
  `.claude/agents/`), `docs/operating-model.md` (delegation model and the Lead
  Agent knowledge path); a regression check that `scripts/specforge materialize`
  sets `openspec:task:<id>`.
- Dependency to note, not resolve here: the `specforge-installer` manifest does
  not yet ship `.claude/agents/`; a follow-up to that change adds them to the
  verbatim payload.
- The `/plan` and `/discovery-review` slash commands and the Planning Agent
  persona are specified in the separate `planning-and-discovery-commands`
  change; this change references them and does not define them.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
