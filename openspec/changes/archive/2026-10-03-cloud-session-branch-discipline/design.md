# Design — cloud session branch discipline

## Decision 1 — instruction, not enforcement, is the fix

Because the GitHub proxy does not actually restrict which branch a cloud
session can push (`design.md` research above), there is no enforcement
mechanism to add — the fix is purely informational: tell the session, in the
same canonical place every other hard rule lives, what to do. This mirrors
`unblock-autonomous-sessions`' TASK-UAS-001 (the `EnterWorktree`-vs-`cd` fix):
both are cases where the right behavior is already reachable, just never
instructed, for a session type whose default tooling nudges it toward the
wrong default.

Placed in **both** `templates/claude-block.md` (installs into a consumer's
`CLAUDE.md`) and `AGENTS.md`'s own `### Claude Code` tool notes (mirrored by
`templates/agents-block.md` into a consumer's `AGENTS.md`), matching the
established two-places pattern. Wording: the `claude/*` branch is never a PR
source; the branch `nogg worktree implement`/`worktree plan` allocated is
the one to push and open a PR from.

## Decision 2 — the SessionStart hook is optional and inert locally

Fresh cloud containers do not carry a locally-configured `core.hooksPath` or
an initialized Beads database — a clone starts from whatever the repository
itself carries, and `.beads/hooks` activation and `bd bootstrap` are
one-time, environment-specific setup steps a local checkout already has from
`scripts/install-hooks`/`bd init`. The template hook:

```bash
if [ "$CLAUDE_CODE_REMOTE" != "true" ]; then
  exit 0
fi
# install pinned bd/Dolt versions per docs/nogging/compatibility.md,
# set core.hooksPath, run bd bootstrap
```

Shipped as a template under the installer's payload (not auto-wired into
every consumer's `.claude/settings.json` by default — a `SessionStart` hook
runs real setup work with real time cost, which a repository should opt into
deliberately, the same caution `codex-prompts-link` already applies to its
own optional linking step). Installation docs tell the operator how to wire
it in for a project that uses cloud sessions.

## Decision 3 — the branch-name hint names the mechanism, not just the symptom

`scripts/check-branch-name`'s existing failure message already prints the
generic convention reminder. When the rejected ref matches `^claude/`, it
additionally prints: "cloud session branch: push the worktree branch from
`nogg worktree implement` instead" — naming the actual fix, not just
repeating that the name is wrong, since a cloud session hitting this in CI
has no interactive operator to ask what to do next.

## Decision 4 — doctor's cloud detection is informational only

`doctor` reports, as a NOTE (never a FAIL — matching every other
environment-presence check it already makes), whether it is running in a
cloud session (`CLAUDE_CODE_REMOTE=true`) and, if so, whether `core.hooksPath`
is set and `bd` is on `PATH`. This gives an operator debugging a stalled
cloud integration the same visibility `doctor` already gives for a missing
`codex`/`pi` or an un-enabled orchestrator service — it does not change
`doctor`'s exit code and does not attempt to fix anything itself.

## Non-goals

- No change to the branch-naming rule itself.
- No automatic branch push or PR creation added to the hook — it only
  prepares the environment (hooks, `bd`), consistent with Nogging never
  wrapping an agent's own git/PR actions.
- `bd dolt push`'s cloud-proxy limitation stays out of scope (`proposal.md`).
