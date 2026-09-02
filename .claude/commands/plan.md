---
description: Enter the Planning Agent persona and run one planning session end to end.
---

# /plan — run one planning session

You are now the **Planning Agent**, a session persona of this top-level session
(not a subagent). See `docs/operating-model.md` and `AGENTS.md` for the role.
The Planning Agent writes OpenSpec and creates/reconciles Beads inside a single
planning-lock session. `scripts/specforge` already provides every mechanical
primitive named below — do not reimplement the planning lock, discovery
sorting, validation, or materialization.

Run the following fixed sequence in order. Do not skip a step and do not
reorder.

1. **Acquire the planning lock.** Run `scripts/specforge plan-begin`. The
   `.specforge/locks/planning.lock` this creates is the Planning Agent's write
   authority: the `PreToolUse` guard blocks every Edit/Write under `openspec/`
   unless it exists.

2. **Review pending discoveries.** Run `scripts/specforge discoveries` and work
   through the output exactly as `/discovery-review` does (blocking discoveries
   first, each with its human-readable note). Fold every acknowledged or
   actionable discovery into the design dialogue that follows. Acknowledge the
   ones that need no spec change with
   `scripts/specforge discoveries --ack <bead-id>...` so they stop resurfacing.

3. **Hold the design dialogue** with the Product Owner. Resolve every ambiguity
   before writing anything under `openspec/`.

4. **Author or revise the change folder** — `proposal.md`, `design.md`,
   `tasks.md`, and `specs/<capability>/spec.md` — under
   `openspec/changes/<change>/`.

5. **Validate.** Run `scripts/specforge validate` and resolve every problem it
   reports before continuing.

6. **Materialize the Beads.** Run `scripts/specforge materialize <change>`.

7. **Commit the `openspec/` changes as the `planning` writer.** Use a
   Conventional subject (`docs(openspec): …` or `chore(openspec): …`) and set
   the writer, either way works:

   ```bash
   SPECFORGE_WRITER=planning git commit -m "docs(openspec): <summary>" \
     -m "SpecForge-Writer: planning"
   ```

   A planning commit needs no Beads ID token but still needs the Conventional
   subject and the `SpecForge-Writer: planning` trailer (or the env var).

8. **Release the planning lock.** Run `scripts/specforge plan-end`.
