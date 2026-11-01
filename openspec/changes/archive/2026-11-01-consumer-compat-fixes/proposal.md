## Why

Source: GitHub issue #382, a consumer project's report of the local edits it carried
over Nogging 3.3.0 and what the forced update to 3.6.0 undid. Only two of its seven
points are in this change; the rest (per-task branches, note redaction in sync, the
writer gate, the Antigravity guard, the Lead hand-off policy) are product decisions and
go to the Product Owner.

1. **A project with a lower-case Bead prefix cannot commit.** Beads builds IDs from the
   repository name, so a consumer's IDs look like `myproject-1ab2`. The `commit-msg`
   hook (`bead_token='\[[A-Z][A-Z0-9]*-[0-9a-z]+\]'`) refuses `fix(x): y [myproject-5nql]`
   with exit 1, and `.beads/hooks/commit-msg` runs the checkout's copy, so every Bead
   commit in every worktree is refused. `LIMBO_TOKEN_RE` in `scripts/nogg` has the same
   upper-case prefix, so `doctor` and `recover` stop seeing those commits and the LIMBO
   warnings vanish without the Beads being resolved. The hook's own message already
   says "a lower-case/digit id", but only for the suffix.
2. **The shipped files return release-scan findings.** The template ships values that a
   consumer's release scan reports as environment-specific data: the usage author
   address `usage@nogging.local` (`scripts/lib/token_usage_store.py`,
   `scripts/lib/token_usage_sync.py`), fixture addresses in the test fixtures
   (`scripts/pre-rebase-guard.test.sh`, `scripts/worktree-workflow.test.sh`,
   `scripts/agent-routing.test.sh`) and an example home path in
   `templates/claude/orchestrator-permissions.example.json`. They are placeholders, not
   personal data, but each consumer has to edit them out again after every update.

## What Changes

- **Bead token.** The accepted prefix becomes letters of either case. The hook and
  `LIMBO_TOKEN_RE` take the same pattern, `[A-Za-z][A-Za-z0-9]*-[0-9a-z]+`. The suffix
  stays lower-case and digits, so `[BEAD-XXX]`, `[bead-XXX]` and `[]` remain refused. It
  is not derived from the Beads `issue_prefix`: the hook also runs in CI and in a
  checkout with no Beads database, where the prefix is unknown.
- **Neutral placeholders.** The usage author becomes `Nogging Usage <usage@nogging.bot>`,
  the roster domain the persona addresses already use. The three fixtures use one
  neutral roster-domain address, and the template's example path no longer names a home
  directory. `scripts/agent-routing.test.sh` is checked for the same findings.

## Impact

- `scripts/hooks/commit-msg`, `scripts/nogg` (`LIMBO_TOKEN_RE`), `docs/architecture.md`.
- `scripts/lib/token_usage_store.py`, `scripts/lib/token_usage_sync.py`, three fixture
  scripts, `templates/claude/orchestrator-permissions.example.json`.
- Existing commits that carry an upper-case token stay valid. A Dolt usage store already
  initialised under the old author keeps its history; only new commits carry the new
  address.
