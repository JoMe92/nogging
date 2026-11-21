---
name: nogging-specialists
description: Delegating isolated work to a specialist and running as one - what stays with the Main Worker, the Co-authored-by trailer, and how each runtime dispatches a specialist. Read it when you delegate work to a specialist or run as one.
---

# Specialists and delegation

## What may be delegated

Isolated implementation or review work may be delegated to a specialist, but
claiming a Bead, closing it, writing the evidence note, and committing stay
with the Main Worker, and no delegated context may write `openspec/`.

Delegate only genuinely isolated work: a self-contained slice, a design
question, a review pass, a test run. Delegating loses context, so it is the
exception. Pass the specialist the Bead ID, the task slice and the relevant
spec excerpt.

## What a specialist does

A specialist works exactly one already-claimed Bead, returns a structured
result, and never claims, closes, re-statuses or commits, and never writes
`openspec/`. A plan-relevant finding from a specialist is recorded as a
discovery by the Main Worker, not by the specialist.

## The trailer

When a specialist's delegated, incorporated work contributes to a commit, add
a `Co-authored-by: <specialist persona name> <specialist persona email>`
trailer naming that specialist (roster in `.nogging/config.json`'s `personas`
key), in addition to the Bead-ID token and the evidence note.

## Dispatch per runtime

- **Claude Code.** Specialists are the `.claude/agents/*.md` roster
  (`architect`, `ui-ux-designer`, `backend-engineer`, `frontend-engineer`,
  `code-reviewer`, `test-runner`), invoked in process through the Task tool.
- **Codex.** No in-process subagent mechanism: a specialist run is a separate
  supervised session, `scripts/nogg session launch --agent codex --role
  specialist:<type> --bead <id>`, under every specialist boundary rule.
- **Pi.** No in-process subagent mechanism: a specialist run is a separate
  supervised session, `scripts/nogg session launch --agent pi --role
  specialist:<type> --bead <id>`, under every specialist boundary rule.
- Where a separate session is overkill, the Main Worker does the work inline
  under the same constraints, and adds no specialist trailer.

The `nogging-sessions` skill carries the full notes for each runtime.
