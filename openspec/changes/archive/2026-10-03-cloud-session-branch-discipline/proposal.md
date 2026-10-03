# Cloud session branch discipline

## Source

[GitHub issue #26](https://github.com/JoMe92/nogging/issues/26), filed the
same day as this planning session. Claude Code on the web (cloud sessions)
assigns every session its own branch (e.g. `claude/first-release-status-2ixixb`).
Nogging requires every implementation branch to be `<type>/<slug>`
(`scripts/check-branch-name`, enforced by `pre-push` and the CI `invariants`
job). `claude/*` never matches, so a PR opened from a cloud session's own
branch into `develop` always fails CI with:

```
Nogging: branch 'claude/first-release-status-2ixixb' does not match <type>/<slug>.
```

Observed downstream (moviemakery2k, Nogging 2.0.x): a cloud Lead session
correctly ran `nogg worktree implement` (creating conformant branches like
`fix/add-slideshow-mvp`), delegated, committed with Bead tokens, closed — then
integration stalled, because the agent pushed its assigned `claude/*` branch
instead of the conformant ones, and `check-branch-name` rejected it.

## Research performed

- Fetched the current Claude Code docs for cloud sessions
  (`/docs/en/claude-code-on-the-web`, `/docs/en/cloud-environments`) directly,
  rather than taking the issue's technical framing on faith.
- **One correction to the issue's stated certainty**: the issue says "the
  agent **may only push** to that one branch" and "the conformant branches
  **could not be pushed** without extra user permission." The current docs
  state the opposite at the infrastructure level — the GitHub proxy's own
  push restrictions are: *"the proxy rejects branch deletions and pushes of
  anything other than a branch, such as a tag. It doesn't limit which
  branches a push can update."* Auto mode's classifier likewise allows
  "pushing to any branch of the repository you're working in" by default.
  So there is no hard technical block on pushing a conformant branch from a
  cloud session. What the issue actually observed is a **default-behavior**
  problem, not a capability one: nothing tells a cloud session to push
  anything other than its own assigned branch, so — left to its own
  judgment, with no instruction saying otherwise — it naturally pushes the
  one branch it was handed. The fix the issue proposes (an explicit
  instruction) is still exactly right; only the stated reason changes from
  "cannot" to "has no reason to do otherwise unless told."
- Confirmed `CLAUDE_CODE_REMOTE` is a real, documented environment variable:
  set to `"true"` inside every cloud session VM, never true locally — this
  project's own docs give it as the canonical cloud-session guard for a
  `SessionStart` hook. `CLAUDE_CODE_REMOTE_SESSION_ID` also exists, for a
  traceable session link in commit/PR bodies if ever wanted later (not used
  by this change).
- Read `scripts/check-branch-name` directly: the exact line to extend with a
  cloud-specific hint is its `claude/*`-unmatched failure message.
- Confirmed the managed-instruction-block precedent: a Claude-only addition
  belongs in **both** `templates/claude-block.md` (what installs into a
  consumer's `CLAUDE.md`) and `AGENTS.md`'s own `### Claude Code` *Tool
  notes* subsection (this repository's own canonical copy, which
  `templates/agents-block.md` mirrors into a consumer's `AGENTS.md`) — the
  same two-places pattern an earlier Pi-subsection gap (SPEC-vppw) already
  established and fixed.

## Why

The rule itself (branch name traceable to an OpenSpec change) is correct and
stays unchanged — the issue's own "alternatives considered" section already
rejects loosening it, for the right reason: `claude/*` carries no
information about what change or Bead the work belongs to. The gap is purely
that a cloud session has never been told what a local one learns from
`AGENTS.md`'s worktree instructions by default: that the branch it should
push is the one `nogg worktree implement` created, not whatever branch it
happened to start on.

## What Changes

- A **Cloud sessions** rule in `templates/claude-block.md` and `AGENTS.md`'s
  `### Claude Code` tool notes: the assigned `claude/*` branch is never a PR
  source; push the `nogg worktree implement`-allocated branch and open the
  PR from that.
- An optional `SessionStart` hook template, guarded by `CLAUDE_CODE_REMOTE`
  (no-op locally), that installs the pinned `bd`/Dolt versions, sets
  `core.hooksPath`, and runs `bd bootstrap` in a fresh cloud container.
- `scripts/check-branch-name` gains a cloud-specific hint when the rejected
  branch matches `claude/*`: "cloud session branch: push the worktree branch
  from `nogg worktree implement` instead."
- `scripts/nogg doctor` detects a cloud session (`CLAUDE_CODE_REMOTE=true`)
  and reports whether hooks are active and whether `bd` is installed.

## Out of scope

- `bd dolt push` to `refs/dolt/data` failing in a cloud session (the GitHub
  proxy's push restriction *does* apply there — it rejects anything that
  isn't a branch, and `refs/dolt/data` is a non-branch ref). The issue
  itself flags this as needing its own design and tracks it separately; it
  is adjacent to, but materially different from, `multi-machine-beads-sync`
  (already planned) since it's about a specific transport's limitation, not
  about cross-machine pull/push protocol. Left for a future issue.
- No change to `check-branch-name`'s actual rule — only its message for one
  recognizable case.
