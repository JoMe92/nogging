# Design — distinct commit identities per Nogging persona

## The persona roster

| Slug | `user.name` | Tier-1 `user.email` | Set where |
| --- | --- | --- | --- |
| `planner` | Nogging Planner | `planner@nogging.bot` | every `plan/<id>/<desc>` worktree |
| `lead` | Nogging Lead | `lead@nogging.bot` | every `<type>/<slug>` implementation worktree |
| `orchestrator` | Nogging Orchestrator | `orchestrator@nogging.bot` | the orchestrator's own session, when it commits under an explicit takeover |
| `sync` | Nogging Sync | `sync@nogging.bot` | nowhere new — matches the existing `Nogging-Writer: sync` mirror commit |
| `architect` | Nogging Architect | `architect@nogging.bot` | `Co-authored-by:` only (specialist, never commits itself) |
| `ux-reviewer` | Nogging UX Reviewer | `ux-reviewer@nogging.bot` | `Co-authored-by:` only |
| `backend-engineer` | Nogging Backend Engineer | `backend-engineer@nogging.bot` | `Co-authored-by:` only |
| `frontend-engineer` | Nogging Frontend Engineer | `frontend-engineer@nogging.bot` | `Co-authored-by:` only |
| `code-reviewer` | Nogging Code Reviewer | `code-reviewer@nogging.bot` | `Co-authored-by:` only |
| `test-runner` | Nogging Test Runner | `test-runner@nogging.bot` | `Co-authored-by:` only |

The roster lives as one data file (`.nogging/config.json`'s new `personas`
key, or a small dedicated `.nogging/personas.json` — implementation picks
whichever fits the existing config-loading code better) so Tier 2's
per-persona GitHub App mapping (below) extends the same records rather than
introducing a second roster that could drift from the first.

## Decision 1 — worktree-scoped identity, not global or per-commit flags

Every Nogging session already works inside its own allocated worktree
(`agent-worktrees` capability) except the orchestrator, which works at the
shared checkout. Setting identity **once, at worktree-allocation time**,
scoped with `git config --worktree` (verified experimentally to isolate
correctly — see `proposal.md`), means every commit made from that worktree
for the rest of its life carries the right identity automatically, with no
per-commit flag an agent could forget to pass. This also means a Lead
session's own `git commit` calls (today's bare `git commit -m "..."`)
need **no code change at all** — identity resolution happens below the
command, exactly the way `git config user.name` always has.

`extensions.worktreeConfig` SHALL be set once per shared repository
(checked first; a repo that already has it is untouched) by
`worktree plan`/`worktree implement`, since both are the only two places
Nogging creates a worktree.

## Decision 2 — specialists get `Co-authored-by:`, not their own commit

Since specialists structurally never commit (confirmed in `proposal.md`),
their identity cannot be a commit *author*. Git's own `Co-authored-by:
Name <email>` trailer is the correct, native mechanism — GitHub already
renders one avatar per matching trailer on a commit, multiple specialists
can be credited on one commit, and it requires no change to how commits are
authenticated or pushed. The Lead Agent delegation protocol gains one
instruction: when a specialist's returned work is incorporated, add that
specialist's `Co-authored-by:` line before committing. This is additive to
the existing evidence-note/Bead-ID-token/`Nogging-Writer` conventions, not a
replacement for any of them.

## Decision 3 — Tier 2 is additive per persona, never all-or-nothing

A persona entry in the roster gains an optional `github_app` block (App ID,
and a path to where its private key is stored — host-level, e.g.
`~/.config/nogging/bot-identities/<slug>.pem`, never inside the repository
and never committed, matching the project's existing never-echo-a-credential
rule verbatim). When present, `worktree plan`/`worktree implement` *also*
wires a worktree-scoped `credential.helper` for that worktree pointing at a
new `scripts/nogg credential-helper <slug>` command, and sets the
worktree's `user.email` to the GitHub-assigned bot format
(`<app-user-id>+<slug>[bot]@users.noreply.github.com`) instead of the Tier-1
placeholder. When absent, the worktree gets the Tier-1 identity and the
default credential path (whatever the session already authenticates with)
— unaffected. A Product Owner can register a GitHub App for, say, only
`lead` and `backend-engineer` and leave the rest on Tier 1; both states are
fully supported simultaneously, not a global switch.

`scripts/nogg credential-helper <slug>` implements git's credential-helper
protocol: on `get`, it exchanges the App's private key for a short-lived
(~1 hour, matching the precedent's lifetime) installation access token via
a signed JWT request to GitHub's Apps API, and returns it as the `password`
field (`username` is `x-access-token`, GitHub's documented convention for
App installation tokens over HTTPS). It never writes the token to disk;
each `git push` mints a fresh one. The remote for a Tier-2-configured
worktree SHALL be HTTPS, not SSH, since installation tokens authenticate
over HTTPS Basic auth, not SSH keys.

## Decision 4 — interaction with existing trailers, unaffected

`Nogging-Writer: planning`/`Nogging-Writer: sync` and the `[<bead-id>]`
subject token are unchanged by this change — they are the write-boundary
and audit-trail mechanisms, orthogonal to *who GitHub displays as the
author*. A planning commit still carries `Nogging-Writer: planning` in its
body; its author is now also, additionally, `Nogging Planner` rather than
the operator's own identity. The `commit-msg` hook's rules (Conventional
subject, Bead-ID token or writer trailer) are unaffected — nothing about
them inspects the author field.

## Decision 5 — the orchestrator's own identity

The orchestrator does not normally commit (orchestrate-only by default).
Under an explicit `/orchestrate takeover plan` or `takeover code`, it
commits from whatever checkout it is already working in — typically the
shared checkout, not an isolated worktree it allocated for itself the way a
Lead/Planning session does. `scripts/nogg orchestrator run` SHALL set the
`Nogging Orchestrator` identity with `git config --worktree` on the shared
checkout at startup (harmless even though the shared checkout is not a
*linked* worktree — `--worktree` config works identically on a repository's
main working tree once `extensions.worktreeConfig` is set there too),
rather than leaving a takeover commit under the operator's own identity by
omission.

## Non-goals

- No change to which commits require which trailer, or to the `commit-msg`/
  `pre-tool-use-openspec-guard` hooks' own logic.
- No attempt to give a specialist its own pushable credential — specialists
  never push, only Lead/Planning/Orchestrator sessions do.
- The persistent per-persona knowledge-store idea (`proposal.md`, *Out of
  scope*) is not designed here.
