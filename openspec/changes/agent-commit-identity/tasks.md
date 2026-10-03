# Tasks — distinct commit identities per Nogging persona

## Tier 1 — no external dependency

- [x] TASK-ACI-001 Add the persona roster (`design.md` table) as data —
      `.nogging/config.json`'s new `personas` key or a dedicated
      `.nogging/personas.json`, whichever fits the existing config-loading
      code more cleanly. Each entry: slug, `user.name`, Tier-1
      `user.email`, optional (absent by default) `github_app` block.

- [x] TASK-ACI-002 In `worktree plan`/`worktree implement`, set
      `git config extensions.worktreeConfig true` on the shared repo if not
      already set (idempotent, checked first), then
      `git config --worktree user.name/user.email` for the matching persona
      (`planner` for a planning worktree, `lead` for an implementation
      worktree) inside the worktree just allocated.

- [x] TASK-ACI-003 Set the `Nogging Orchestrator` identity
      (`design.md`, Decision 5) at `scripts/nogg orchestrator run` startup
      on the shared checkout, after confirming
      `extensions.worktreeConfig` there too.

- [x] TASK-ACI-004 Give `sync()`'s existing mirror commit the `Nogging Sync`
      identity (it already carries `Nogging-Writer: sync`; add the matching
      `user.name`/`user.email` at the point it commits, scoped the same
      worktree-config way if `sync` runs from a worktree, or directly via
      the commit's author/committer override if simpler given where `sync`
      actually runs from — implementer's call, confirm against where the
      sync timer's working directory actually is).

- [ ] TASK-ACI-005 Add the `Co-authored-by:` instruction to the Lead Agent
      delegation protocol everywhere it's documented — `AGENTS.md`,
      `templates/claude-block.md`, `templates/agents-block.md`: when a
      specialist's delegated, incorporated work contributes to a commit, add
      a `Co-authored-by: <specialist persona name> <specialist persona
      email>` trailer naming that specialist, using the roster from
      TASK-ACI-001.

- [ ] TASK-ACI-006 Add a `scripts/nogg doctor` check: report, as a NOTE, any
      worktree whose `user.name` does not match its role's expected persona
      (helps catch a worktree created before this change, or one where
      identity-setting silently failed). Never a FAIL.

## Tier 2 — opt-in GitHub Apps

- [ ] TASK-ACI-007 Write the Product-Owner-facing procedure (new doc,
      e.g. `docs/agent-identities.md`): how to register one GitHub App per
      persona slug (name, minimum permissions — Contents and Pull requests
      read/write), generate its private key, install it on the target
      repository, and where to place the key
      (`~/.config/nogging/bot-identities/<slug>.pem`) plus the App ID in
      the persona's `github_app` config block.

- [ ] TASK-ACI-008 Add `scripts/nogg credential-helper <slug>`: implements
      git's credential-helper protocol; on `get`, mints a short-lived
      GitHub App installation access token (signed JWT exchange against
      GitHub's Apps API) for the named persona's configured App and private
      key, returns `username=x-access-token`, `password=<token>`. Never
      writes the token to disk. Fails closed (non-zero, no credential
      printed) if the key is missing or the exchange fails — never falls
      back to an ambient personal credential silently.

- [ ] TASK-ACI-009 When `worktree plan`/`worktree implement` allocates a
      worktree for a persona whose roster entry has a `github_app` block:
      set that worktree's `user.email` to the GitHub-assigned bot format
      (`<app-user-id>+<slug>[bot]@users.noreply.github.com`, read from the
      App's own `/app` API response rather than hand-constructed), force
      the worktree's remote to HTTPS if it is currently SSH, and wire
      `credential.helper` (worktree-scoped) to
      `scripts/nogg credential-helper <slug>`. A persona with no
      `github_app` block is unaffected (stays on Tier 1 from TASK-ACI-002).

- [ ] TASK-ACI-010 Run `scripts/test`. Manually verify Tier 1: a freshly
      allocated planning and implementation worktree each show the correct
      persona in `git config --worktree --get user.name` and a resulting
      commit's author matches, while the shared checkout and other
      worktrees are unaffected. Manually verify Tier 2, if a throwaway
      GitHub App is available during implementation: a commit pushed from a
      Tier-2-configured worktree shows the `[bot]` badge on GitHub.
