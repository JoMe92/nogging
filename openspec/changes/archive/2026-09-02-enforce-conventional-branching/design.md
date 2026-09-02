# Design

## Context

`docs/operating-model.md` already asks for Conventional Branches
(`feat/<change-id>`, `fix/<change-id>`, `chore/<topic>`) and Conventional
Commits with a Bead reference. `scripts/hooks/commit-msg` implements the commit
half: a subject matching
`^(build|chore|ci|docs|feat|fix|perf|refactor|revert|test)(\(scope\))?(!)?: .+`
and, unless `SPECFORGE_WRITER` is `planning` or `sync`, a token
`\[[A-Z][A-Z0-9]*-[0-9a-z]+\]` somewhere in the subject.

Two things defeat that hook in practice:

- **`core.hooksPath` is `.beads/hooks` in this repo.** Git therefore never runs
  `.git/hooks/commit-msg` or `.git/hooks/pre-commit` here. `docs/architecture.md`
  records this. Local commit discipline is effectively unenforced in this
  repository, and only advisory in a fresh install if Beads later diverts the
  path there too.
- **CI does not look.** `.github/workflows/specforge-validate.yml` has
  `script-tests`, `installer` and `validate` jobs. None reads the branch name
  or walks the commit range of a pull request.

The worked example is on the branch this change is planned on: the commit
`plan: amend specforge-installer so init leaves the repo ready to start` is not
a Conventional Commit type and carries no Beads ID. It exists only because the
local hook is bypassed and CI never checks the history.

## Goals / Non-goals

- Goal: a branch name alone tells a reviewer which OpenSpec change — or which
  topic — a pull request advances, and CI enforces it.
- Goal: the `commit-msg` rule (Conventional subject + real Beads ID token, with
  a planning/sync exemption) is enforced on every pull-request commit, not only
  where `.git/hooks` happens to run.
- Goal: the writer exemption travels inside the commit object, so the local
  hook and CI apply it identically.
- Non-goal: changing the *content* of the commit-message rule — the Conventional
  type set, the Beads-ID token shape, the "subject only" scope.
- Non-goal: branch-per-Bead. SpecForge runs one branch per change carrying many
  Beads; a branch maps to a change, not a Bead.
- Non-goal: auto-creating or renaming branches, choosing a merge strategy,
  release tagging.
- Non-goal: materializing Beads or editing implementation files in this
  planning session.

## Decisions

### Branch-naming convention

A working branch is `<type>/<slug>`:

- `<type>` is one of `feat`, `fix`, `chore`, `docs`, `refactor`, `perf`,
  `test`, or `plan`. `plan` is not a Conventional Commit type but is a valid
  branch type for a planning-session branch.
- For a **change branch** (every `<type>` except a bare topic), `<slug>` MUST
  equal the directory name of an existing `openspec/changes/<slug>/` (never
  `archive`). This is what makes the branch traceable to agreed intent.
- `chore/<topic>` and `plan/<topic>` are for work not scoped to a single change
  — tooling, multi-change planning. `<topic>` is a free kebab slug; no
  `openspec/changes/` match is required.
- `main` and `develop` are protected and exempt.
- If CI cannot resolve a real branch ref (detached HEAD, empty `head_ref`), the
  check fails closed with an explicit message rather than passing silently.

This tightens the existing `docs/operating-model.md` wording: "change-id"
becomes "the `openspec/changes/` directory name", and `plan/` is added. The
current branch `feat/specforge-installer` already complies.

CI resolves the head branch from `${{ github.head_ref }}` (populated on
`pull_request`).

### One branch-name rule, one implementation

The branch-name rule lives in a single script (for example
`scripts/check-branch-name <ref>`): exit non-zero with an actionable message
for a non-conforming name, and for a change branch also assert that
`openspec/changes/<slug>/` exists in the working tree. Both the `pre-push` hook
and the CI job call this script; neither re-encodes the rule.

### Portable writer marker

Planning and sync commits gain a Git trailer in the message body:
`SpecForge-Writer: planning` or `SpecForge-Writer: sync`.

- `scripts/hooks/commit-msg`: the exemption test becomes "`SPECFORGE_WRITER` is
  `planning`/`sync` **or** the message body contains a matching
  `SpecForge-Writer:` trailer". The env var keeps working for local use;
  back-compat is preserved.
- `scripts/specforge` adds the trailer to its deterministic sync commit.
- The planning workflow (docs, and any guidance `scripts/specforge` prints)
  switches from the `plan:` subject to a Conventional subject — `docs(openspec):
  …` or `chore(openspec): …` — plus the `SpecForge-Writer: planning` trailer.

The commit-message rule itself is unchanged: a commit is still valid only if it
is a writer commit or carries a real Beads ID token, and it always needs a
Conventional subject.

### CI invariant job

A new job `invariants` in `specforge-validate.yml`, `on: pull_request`:

1. `actions/checkout@v4` with `fetch-depth: 0`; fetch the base ref
   (`git fetch origin ${{ github.base_ref }}`).
2. Check `${{ github.head_ref }}` with `scripts/check-branch-name`.
3. Enumerate the introduced commits:
   `git rev-list --no-merges origin/${{ github.base_ref }}..HEAD`.
4. For each, write `git show -s --format=%B <sha>` to a temp file and invoke
   `scripts/hooks/commit-msg` on it — so the rule has exactly one
   implementation and the trailer exemption works unchanged.
5. On the first violation, print the branch or the commit SHA and subject and
   the specific rule broken; exit non-zero.

It is a distinct job so its failure sits legibly next to `validate` and
`script-tests`.

### Local pre-push hook, minimal

`scripts/hooks/pre-push` checks only the current branch name via
`scripts/check-branch-name` (fast, no network) and blocks a non-conforming push
with the same message CI uses. It does not re-check commit messages — that is
`commit-msg`'s job, per commit, where `.git/hooks` is active.
`scripts/install-hooks` installs it next to `commit-msg` and `pre-commit`.
Because `core.hooksPath` is diverted in this repository the hook is advisory
here; it is real in a fresh install with `.git/hooks` active. CI remains the
authority.

## Risks / open questions

- The PR range needs `fetch-depth: 0` and an explicit fetch of the base ref; a
  shallow checkout breaks `git rev-list`.
- `github.head_ref` is empty for `push` events; the job is `pull_request`-only
  by design. A branch pushed without a PR is unchecked until a PR opens —
  acceptable.
- Retiring `plan:` means the planning docs and any `scripts/specforge` help
  text must change in lockstep. `reliable-beads-sync` also edits planning docs;
  sequence the two to avoid a merge conflict.
- A commit made locally with only `SPECFORGE_WRITER` set and no trailer passes
  locally but fails CI (CI sees no trailer). The contributor message must call
  this out: for a commit that will reach a PR, use the trailer.
- Renaming a change's `openspec/changes/<slug>/` directory mid-PR makes the
  branch start failing. That is the intended signal — branch and change must
  agree.
