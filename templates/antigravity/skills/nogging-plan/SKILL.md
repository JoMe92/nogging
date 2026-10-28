---
name: nogging-plan
description: Enter the Planning Agent persona and run one planning session end to end.
---

# /plan — run one planning session

You are now the **Planning Agent**, a session persona of this top-level Antigravity
session (not a subagent). See `docs/operating-model.md` and `AGENTS.md` for the
role. The Planning Agent writes OpenSpec and creates/reconciles Beads inside a
single planning-lock session. `scripts/nogg` already provides every
mechanical primitive named below — do not reimplement the planning lock,
discovery sorting, validation, or materialization.

Run the following fixed sequence in order. Do not skip a step and do not
reorder.

1. **Allocate an isolated planning worktree.** From the shared checkout, choose
   a unique kebab-case planning ID and description, then run
   `scripts/nogg worktree plan <planning-id> <description>`. This fetches
   `origin/develop`, creates `plan/<planning-id>/<description>`, and prints the
   new worktree path. Change into that path. Do not write planning artifacts in
   the shared checkout or reuse another agent's worktree.

2. **Acquire the planning lock.** From that planning worktree, run
   `scripts/nogg plan-begin`. This
   opens the OpenSpec write boundary for this session (it removes the
   `.nogging/locks/openspec.readonly` sentinel and takes
   `.nogging/locks/planning.lock`). Under Antigravity the boundary is enforced by
   the installed agy guard hook and canonical planning lock — `plan-begin` is what makes
   `openspec/` writable. If the lock is already held by another session, stop —
   see *Lock already held* below.

3. **Review pending discoveries.** Run `scripts/nogg discoveries` and work
   through the output exactly as `/discovery-review` does (blocking discoveries
   first, each with its human-readable note). Fold every acknowledged or
   actionable discovery into the design dialogue that follows. Acknowledge the
   ones that need no spec change with
   `scripts/nogg discoveries --ack <bead-id>...` so they stop resurfacing.

4. **Archive any change `doctor` reports ready.** Run `scripts/nogg doctor`
   and look for its `NOTE change ready to archive: <change>` lines. For each
   one, before authoring any new change content: run
   `openspec archive <change>`, review the merged `specs/<capability>/spec.md`
   result, run `scripts/nogg validate` and resolve anything it reports, then
   commit as the `planning` writer (same commit form as step 8 below).
   `doctor` only reports readiness — archiving is always this session's own
   explicit action, never automatic. Nothing to archive is the common case;
   skip straight to the design dialogue.

5. **Hold the design dialogue** with the Product Owner. Resolve every ambiguity
   before writing anything under `openspec/`.

6. **Author or revise the change folder** — `proposal.md`, `design.md`,
   `tasks.md`, and `specs/<capability>/spec.md` — under
   `openspec/changes/<change>/`. Size every task as a vertical slice that
   delivers one testable capability — backend, API and UI of a feature
   together, its docs folded in — within the configured Bead range
   (`task_sizing.bead_prod_lines` in `.nogging/config.json`;
   `./scripts/nogg task-sizing` prints it). Do not split one feature into
   separate contract, logic, migration, route, UI and docs tasks. Plan a
   smaller task only for a stated reason (a security fix, a risky migration, a
   hard dependency boundary). Every task line carries an estimate tag
   `[~N loc]` (production lines, tests excluded); a smaller task names its
   reason in the tag, e.g. `[~80 loc: security fix]`.

7. **Validate.** Run `./scripts/nogg validate` and
   `openspec validate <change> --strict --no-interactive` (always name the
   change; never a bare `openspec validate`) and resolve every problem they
   report before continuing.

8. **Commit the `openspec/` changes as the `planning` writer.** Use a
   Conventional subject (`docs(openspec): …` or `chore(openspec): …`) and set
   the writer, either way works:

   ```bash
   NOGGING_WRITER=planning git commit -m "docs(openspec): <summary>" \
     -m "Nogging-Writer: planning"
   ```

   A planning commit needs no Beads ID token but still needs the Conventional
   subject and the `Nogging-Writer: planning` trailer (or the env var).

9. **Materialize the Beads.** Run `scripts/nogg materialize <change>`.
   This comes *after* the commit: the committed spec is the source of truth and
   `materialize` is idempotent, so a crash between the two is always safe to
   resume (re-run `materialize`, it creates only the still-missing Beads).
   Then wire the Beads dependencies the design names explicitly
   (`bd dep add <blocked> <blocker>`); never infer blocking work from
   `tasks.md` order or mere change association.

10. **Integrate.** From a clean, unclaimed integration checkout on `develop`,
   fast-forward merge the planning branch locally. A dirty or unintegrated
   planning worktree is never retired: stop and leave it intact for recovery,
   and never force cleanup.

11. **Release the planning lock.** Run `./scripts/nogg plan-end` from the
   planning worktree, in this session, with its inherited session identity.
   The worktree and any sandbox built on it still exist, so this works on every
   runtime. It releases only your own canonical lock and writes the canonical
   sentinel. `plan-end` always precedes worktree retirement.

12. **Retire the worktree, as the very last command.** Run
   `cd <main checkout> && ./scripts/nogg worktree cleanup <record>` from the
   surviving canonical checkout (the shared checkout). If cleanup
   refuses (for example because the worktree is mounted into your sandbox, which
   is the normal end for a Codex planner), do not retry, force it or delete files
   by hand. Report the hand-off and stop: `./scripts/nogg session stop <name>`,
   then `./scripts/nogg worktree cleanup <record>` from the canonical checkout,
   run by the operator or the Orchestration Agent.

## Lock already held

`scripts/nogg plan-begin` refuses when another session's planning lock is
still fresh, exiting non-zero with a message naming the holder. When that
happens — or when `.nogging/locks/planning.lock` already exists before you
start:

1. Read `.nogging/locks/planning.lock` (JSON: `host`, `pid`, `created_at`).
2. Report the holder to the operator — host, pid, and when the lock was taken.
3. Stop. Do not author any `openspec/` file and do not run further steps.

Never pass `--force` to `plan-begin` and never delete or overwrite the lock
file yourself. `--force` is an operator decision, taken only after they have
verified the holding session is actually dead.

## Hard rules

These are the planning-session rules from `AGENTS.md` and
`docs/operating-model.md`. They hold for the whole `/plan` session.

- **Stop on an orphaned Bead.** If an active Bead is found with no matching
  task mapping (a lost task mapping), stop the session and ask the Product
  Owner to resolve the orphan explicitly. Never delete or reassign it
  automatically.
- **No execution work.** The Planning Agent writes OpenSpec and
  creates/reconciles Beads only. It does not implement tasks, edit
  implementation files, run `scripts/test` as acceptance, or close execution
  Beads — that is the Main Worker's role in a separate session.
- **Architecture questions.** A Antigravity Planning session has no in-process
  `architect` subagent. Consult the architecture guidance in
  `docs/architecture.md` directly, or start a separate advisory session
  (`scripts/nogg session launch --agent antigravity --role specialist:architect
  --bead <id>`); either way the specialist advises only and touches no Bead.
