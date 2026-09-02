# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->


## Lead Agent delegation

This section sits **alongside** the managed Beads block above, not inside it, and
does not change it. It defines how the Lead Agent (the default persona of this
session — see `docs/operating-model.md` and `AGENTS.md`) uses the specialist
subagents in `.claude/agents/`.

After claiming a Bead with `bd update <id> --claim` and reading its task slice —
`bd show <id>` gives the `openspec:task:<TASK-ID>` label, and you read only that
one task line in `openspec/changes/<change>/tasks.md` plus the referenced spec
excerpt, not the whole `proposal.md` / `design.md` — you decide:

- **Implement it directly** — the default for anything that needs the context you
  already hold.
- **Delegate to one specialist via the Task tool** — only for genuinely isolated
  work: a self-contained backend or frontend slice, a design question, a review
  pass, a test run. Delegating trivially loses context, so it is the exception,
  not the reflex.

When you delegate, pass into the Task-tool prompt: the **Bead ID**, the **task
slice**, and the **relevant spec excerpt** (plus any `ui-ux-designer` output for a
frontend slice). The six specialists are `architect` (advisory, also usable by
the Planning Agent), `ui-ux-designer` (advisory), `backend-engineer`,
`frontend-engineer`, `code-reviewer` (advisory), and `test-runner`.

A specialist returns a structured result and nothing else. It never claims,
closes, or re-statuses a Bead, never commits, and never writes `openspec/`. On
the specialist's return **you**:

1. validate the work (run `scripts/test` or the narrower suite);
2. write the evidence note — `bd update <id> --append-notes "commit <sha>; <evidence>"`;
3. commit with a Conventional subject carrying the `[<ID>]` token;
4. `bd close <id>`.

If a specialist reports a plan-relevant finding, you record the discovery per
`AGENTS.md` (`bd update <id> --add-label discovery --append-notes "<prose>"`,
`--status blocked` if it blocks). OpenSpec stays **read-only** for the Lead
Agent; an agreed-intent change waits for a planning session.


## Build & Test

_Add your build and test commands here_

```bash
# Example:
# npm install
# npm test
```

## Architecture Overview

_Add a brief overview of your project architecture_

## Conventions & Patterns

_Add your project-specific conventions here_
