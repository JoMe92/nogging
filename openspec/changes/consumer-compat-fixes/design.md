## Context

The two fixes touch different files and share no state, so they are separate, independent
tasks. Every claim below was read from the code at the head of `develop`.

## Decisions

### 1. Accept letters of either case in the token prefix; do not read `issue_prefix`

The accepted token becomes `\[[A-Za-z][A-Za-z0-9]*-[0-9a-z]+\]` in `scripts/hooks/commit-msg`
and `\[([A-Za-z][A-Za-z0-9]*-[0-9a-z]+)\]` in `LIMBO_TOKEN_RE`. Alternatives rejected:

- *Derive the prefix from the Beads `issue_prefix`.* The hook runs in CI (the pull-request
  commit range) and in checkouts without a Beads database, so it would need a fallback
  that is the permissive rule anyway; and a project that changes its prefix would strand
  its older commits.
- *Make the prefix a config key.* More surface for the same effect.

The suffix rule is unchanged, so a placeholder such as `[BEAD-XXX]` or `[bead-XXX]`, and an
empty `[]`, still fail. The only new false positive is a lower-case bracketed word with a
dash and a lower-case or digit tail in a subject (for example `[wip-1]`); the hook then
accepts a commit that names no Bead, and LIMBO ignores a token that matches no Bead. Both
were already true for an upper-case look-alike. The two patterns stay literally identical,
and the commit-msg rule remains the single implementation CI reuses.

### 2. Placeholder addresses use the roster domain

`.nogging/config.json`'s personas already use `<name>@nogging.bot`. The usage author is
`usage@nogging.bot` and the fixtures use one neutral address on that domain, so no new
domain appears. `nogging.local` is dropped. The change is behaviour-neutral: a Dolt commit
author and a fixture's git identity are labels, and no suite depends on the old value
except where it asserts it, which the task updates.

### 3. The template names no home directory

The comment in the permissions template tells the reader to replace `HOME` and `<repo>`;
its example home path is replaced by the unexpanded placeholder form, so the file
carries no concrete home path. The rules keep their `//HOME/src/<repo>-...` placeholders,
which the existing template suite already requires to be free of absolute host paths.

### 4. Scope

Issue #382 points 2 to 5 and 7 are not in this change.
