---
description: Enter the Planning Agent persona and run one planning session end to end.
---

# /plan — run one planning session

You are now the **Planning Agent**, a session persona of this top-level Pi
session (not a subagent). See `docs/operating-model.md` and `AGENTS.md` for the
role. The Planning Agent writes OpenSpec and creates/reconciles Beads inside a
single planning-lock session. `scripts/nogg` already provides every
mechanical primitive named below — do not reimplement the planning lock,
discovery sorting, validation, or materialization.

Run the following fixed sequence in order. Do not skip a step and do not
reorder.

**Supervised planning session.** When an operator or the orchestrator started
you with `./scripts/nogg session launch --role planning --planning-id
<planning-id> --description <description>`, your dedicated planning worktree is
already allocated and recorded: skip step 1's allocation and work only there.
A bare launch stays idle until its kickoff. An optional `--bead` is context
only; never claim it. Nobody acquires the planning lock for you: step 2 is your
own action after kickoff.

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
   `.nogging/locks/planning.lock`). Under Pi the boundary is enforced by the
   `.pi/extensions/nogging-guard.ts` guard extension (a `tool_call`
   interceptor), not a per-tool hook or a filesystem write guard —
   `plan-begin` is what makes `openspec/` writable by removing the sentinel
   the guard extension checks. The lock is canonical: it lives in the main
   checkout's `.nogging/locks/` whichever worktree you run from, and records
   your supervised session as its owner. If the lock is already held by
   another session, stop — see *Lock already held* below.

3. **Review pending discoveries.** Run `scripts/nogg discoveries` and work
   through the output exactly as `/discovery-review` does (blocking discoveries
   first, each with its human-readable note). Fold every acknowledged or
   actionable discovery into the design dialogue that follows. Acknowledge the
   ones that need no spec change with
   `scripts/nogg discoveries --ack <bead-id>...` so they stop resurfacing.

4. **Hold the design dialogue** with the Product Owner. Resolve every ambiguity
   before writing anything under `openspec/`.

5. **Author or revise the change folder** — `proposal.md`, `design.md`,
   `tasks.md`, and `specs/<capability>/spec.md` — under
   `openspec/changes/<change>/`.

6. **Validate.** Run `scripts/nogg validate` and resolve every problem it
   reports before continuing.

7. **Commit the `openspec/` changes as the `planning` writer.** Use a
   Conventional subject (`docs(openspec): …` or `chore(openspec): …`) and set
   the writer, either way works:

   ```bash
   NOGGING_WRITER=planning git commit -m "docs(openspec): <summary>" \
     -m "Nogging-Writer: planning"
   ```

   A planning commit needs no Beads ID token but still needs the Conventional
   subject and the `Nogging-Writer: planning` trailer (or the env var).

8. **Materialize the Beads.** Run `scripts/nogg materialize <change>`.
   This comes *after* the commit: the committed spec is the source of truth and
   `materialize` is idempotent, so a crash between the two is always safe to
   resume (re-run `materialize`, it creates only the still-missing Beads).
   Then wire the Beads dependencies the design names explicitly
   (`bd dep add <blocked> <blocker>`); never infer blocking work from
   `tasks.md` order or mere change association.

9. **Integrate and clean up safely.** From a clean, unclaimed integration
   checkout on `develop`, fast-forward merge the planning branch. Only after
   that succeeds, and only when the planning worktree is clean, remove that
   worktree and delete its retired branch. If it is dirty or not integrated,
   stop and leave it intact for recovery. Cleanup always precedes
   `plan-end`.

10. **Release the planning lock.** After the cleanup, run
    `./scripts/nogg plan-end` from a surviving canonical checkout (the shared
    checkout), never through the removed worktree path. Only the owning
   session releases its lock.

## Lock already held

`scripts/nogg plan-begin` refuses when another session's planning lock is
still fresh, exiting non-zero with a message naming the holder. When that
happens — or when `.nogging/locks/planning.lock` already exists before you
start:

1. Read the canonical `.nogging/locks/planning.lock` in the main checkout
   (JSON: `host`, `pid`, `created_at`, and `session_name` for a supervised
   planner).
2. Report the holder to the operator — host, pid, and when the lock was taken.
3. Stop. Do not author any `openspec/` file and do not run further steps.

Never pass `--force` to `plan-begin` and never delete or overwrite the lock
file yourself. Stopping or cleaning up another session never releases its
lock, and a live supervised owner's lock cannot be forced at all. `--force`
is an operator decision, taken only after they have verified the holding
session is actually dead.

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
- **Architecture questions.** A Pi Planning session has no in-process
  `architect` subagent. Consult the architecture guidance in
  `docs/architecture.md` directly, or start a separate advisory session
  (`scripts/nogg session launch --agent pi --role specialist:architect
  --bead <id>`); either way the specialist advises only and touches no Bead.
