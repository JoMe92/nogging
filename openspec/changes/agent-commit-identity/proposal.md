# Distinct commit identities per Nogging persona

## Source

Product Owner request, not a GitHub issue or existing Bead — checked first:
no open or closed GitHub issue, and none of the 309 Beads in the database
(open or closed), cover commit-author identity, bot accounts, or
contributor attribution. The product-identity-renaming Beads that matched
the search terms are about the *project's* name (SpecForge → Nogging), not
about *who authored a commit* — unrelated.

The problem, in the Product Owner's words: every commit Nogging-driven work
produces today is attributed to the Product Owner's own git/GitHub identity.
GitHub shows no distinction between a commit the Product Owner wrote by hand
and one a Planning session, a Lead session, or a specialist's delegated work
produced — "sieht so aus, als ob ich das alles gecodet habe." The
`Nogging-Writer: <role>` commit trailer already exists, but it's a machine-
readable marker in the commit *body*, not something that changes who GitHub
shows as the *author* — invisible unless someone already knows to look.

## Research performed

- **Confirmed the gap is total, not partial.** Grepped `scripts/nogg`,
  `scripts/session-launch`, every command file, and `AGENTS.md` for any
  existing `user.name`/`user.email`/`GIT_AUTHOR_*`/`Co-authored-by` handling:
  none exists anywhere. Every commit in this project's history — planning,
  Lead, sync — carries whatever `git config user.name`/`user.email` already
  resolves to, which today is always the operating human's own identity.
- **How GitHub actually resolves a commit's displayed identity**: GitHub
  matches the commit's raw author *email* against verified emails on GitHub
  accounts. An email matching no account shows as plain text next to a
  generic avatar — readable in the commit list and `git log`, but not a
  recognizable, reusable visual identity. An email matching a GitHub App's
  installation shows the richer `<slug>[bot]` badge with the App's own
  avatar — the same visual pattern `dependabot[bot]`/`renovate[bot]` use.
- **Found a directly precedented, documented pattern for exactly this
  problem** in the current AI-coding-agent ecosystem (not invented from
  scratch): a GitHub App registered per agent/persona, whose installation
  token is used to author and push a commit. A **local** `git commit` +
  `git push` genuinely produces the `[bot]` badge, *provided* the push is
  authenticated with that App's installation token (not a personal
  credential) and the commit's author/committer email matches the format
  GitHub assigns the App: `<app-user-id>+<app-slug>[bot]@users.noreply.github.com`.
  One working open-source implementation of this (`agent-bot-identity`)
  wires it per-worktree via a `post-checkout` hook, a credential helper that
  mints short-lived (~1 hour) installation tokens on demand, and a
  `prepare-commit-msg` hook — architecturally close to what Nogging already
  does per worktree, not a foreign pattern.
- **Verified the mechanical prerequisite experimentally** (not assumed):
  plain `git config --local` inside a linked worktree writes to the
  **shared** `.git/config`, visible from every other worktree of the same
  repository — it does **not** isolate identity per worktree. Isolation
  requires `git config extensions.worktreeConfig true` (a one-time,
  idempotent, non-breaking flag on the shared repo) plus
  `git config --worktree user.name/user.email` set inside each worktree —
  confirmed by direct experiment that this correctly scopes to one worktree
  and leaves every other worktree's (and the main checkout's) identity
  untouched.
- **Specialists never commit themselves** — confirmed by re-reading
  `CLAUDE.md`'s "Lead Agent delegation" section: "A specialist returns a
  structured result and nothing else... never commits." So a specialist
  cannot have its *own* author identity on a commit the way a Planning or
  Lead session can; what it can have is a `Co-authored-by:` trailer on the
  Lead's own commit — a native git/GitHub mechanism (GitHub renders one
  avatar per matching `Co-authored-by:` line on a commit) that needs no new
  infrastructure to work once an identity format is chosen.

## Why

This is squarely feasible, and the two things the Product Owner asked to
know — whether it's possible, and how — have the same answer at two
different investment levels: a **no-new-infrastructure version** that is
accurate and visible today, and a **fully-realized version** with real
`[bot]` avatars that needs the Product Owner to register one GitHub App per
persona (a human action this change cannot perform on the Product Owner's
behalf — creating GitHub identities is an ownership decision, not a
mechanical one).

## What Changes

**Tier 1 — distinct author identity per persona, no external dependency:**

- A fixed roster of Nogging persona identities, one `name`/`email` pair
  each: `Nogging Planner`, `Nogging Lead`, `Nogging Orchestrator`, and one
  per specialist (`Nogging Architect`, `Nogging UX Reviewer`, `Nogging
  Backend Engineer`, `Nogging Frontend Engineer`, `Nogging Code Reviewer`,
  `Nogging Test Runner`), plus the existing mechanical `Nogging Sync`
  writer. Addresses use a placeholder, non-deliverable domain
  (`<slug>@nogging.bot`) — not meant to receive mail, only to be a stable,
  recognizable identity string.
- `scripts/nogg worktree plan`/`worktree implement` set
  `extensions.worktreeConfig` on the shared repo (idempotent, one-time) and
  write the matching persona's `user.name`/`user.email` with
  `git config --worktree` into the worktree they just allocated, keyed off
  the session role that will work there.
- The Lead Agent delegation protocol (`AGENTS.md`, `templates/claude-block.md`,
  `templates/agents-block.md`) adds: when a specialist's delegated work is
  incorporated into a commit, add a `Co-authored-by: <specialist identity>`
  trailer naming which specialist contributed.
- `scripts/nogg sync`'s own mirror commit adopts the `Nogging Sync` identity
  the same way (it already carries the `Nogging-Writer: sync` trailer; this
  adds the matching author identity).

**Tier 2 — real GitHub `[bot]` identities, opt-in, Product-Owner-provisioned:**

- A documented procedure for the Product Owner to register one GitHub App
  per persona they want a real badge for (not required for all of them at
  once — partial adoption works, see `design.md`).
- A `.nogging/config.json` mapping from persona slug to that persona's
  GitHub App ID and where its private key is stored (host-level, outside
  the repository — never committed, matching the project's existing
  never-echo/never-commit-a-credential rule).
- A credential-minting helper, wired as each configured persona's
  worktree-scoped `credential.helper`, that exchanges the App's private key
  for a short-lived installation token on demand — never storing a
  long-lived token on disk.
- A persona with no registered App falls back to Tier 1 automatically — the
  two tiers coexist per persona, not as an all-or-nothing switch.

## Out of scope (explicitly, not silently dropped)

- **Persistent, per-persona "experience" / knowledge accumulation** — the
  Product Owner's own framing of a longer-term direction ("Agenten, die über
  die Zeit... besser werden," their own knowledge store). This is directly
  enabled by this change's identity roster existing (there is now a stable
  slug per persona to attach accumulated knowledge to), and the existing
  `.claude/agents/*.md` specialist definitions plus `bd remember`/`bd
  memories` are the natural substrate to extend — but *how* a persona would
  curate, validate, and apply its own accumulating notes without drifting
  into noise is a genuinely separate, larger design question (who writes an
  entry, when, with what review, how is staleness handled) that deserves its
  own dedicated planning session once the identity roster this change
  creates is in place to build on. Not planned here.
- **Automatic GitHub App registration.** Registering an App is an
  account/ownership action; this change documents the procedure and
  consumes the result, it does not attempt the registration itself.
- **Retroactively re-authoring existing commit history.** This change
  affects commits made after it lands, not a history rewrite of what
  already exists.
