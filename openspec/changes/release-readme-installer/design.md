## Context

The Product Owner asked on 2026-10-17 for one change that makes `develop`
ready for the next release. It covers a README for newcomers, installer polish
seen from a first-time user, and release preparation. Facts gathered while
planning, on `develop` at `5f69f1a`:

**README contracts already enforced by tests.** Any rewrite must keep these
or move them deliberately, in the same commit:

- `scripts/nogging-identity.test.sh` requires `# Nogging` and the headings
  `## Project status and audience`, `## Supported environments`,
  `## Safety warning`, `## Documentation` and
  `## Inspiration and related projects`. It also required the phrase
  `pre-public release candidate`; v3.0.0 is a public release, so RRI-001
  inverts that assertion (the phrase and "release candidate" must be absent
  and the private-repository note below must be present). It also requires
  the Gas Town and Beads links, the
  independence statement (the check is sensitive to line breaks),
  `only Gas Town`, `optional sibling`, the exact line
  `npx github:JoMe92/nogging#v2.2.0 init --no-systemd`, no `git@github.com`,
  and resolvable relative links.
- `scripts/planning-docs.test.sh` lists `README.md` as a planning-flow
  surface. In order, it needs the planning-writer commit, `materialize`,
  `plan-end`, `worktree cleanup` and `surviving canonical checkout`. It also
  needs `--role planning` and `canonical`, and forbids a bare
  `openspec validate --strict`.
- `scripts/security-docs.test.sh` requires a Markdown link labelled
  "security and threat model" that targets `docs/security-model.md` (written
  in the README as bracketed label followed by the parenthesised path) before
  the first `session launch … --full-access` line.
- `scripts/package-publication.test.sh` requires `unscoped npm name` and the
  pinned `github:JoMe92/nogging#v2.2.0`.
- `scripts/commands.test.sh` resolves every `.claude/commands/*.md` mention.
- The `product-identity` spec names the tagline "Structure for what's next.".
  The README has said "Structure for a team of agents." since 2.0.1. This
  change aligns the spec with the README.

**Installer, as a first-time user sees it.** Observed with
`node bin/cli.js init --no-beads` in a fresh scratch repository, then
`update`, `update` after a local edit, `remove --dry-run` and `doctor`:

- No header. The output starts with `Changed:` and a 100-line flat list.
  `.codex/rules/nogging.rules` appears as `create` and again as `unchanged`,
  because both the verbatim copy and the Codex merge log it.
- The next steps come in this order: enable the sync timer, enable the
  orchestrator with linger, then `bd init`. Nothing says which steps are
  required. Nothing mentions `doctor`, a first plan or the README.
- The verdict is
  `Nogging is installed but not ready: uninitialized tracker (run `bd init`); bd list --status open,in_progress,blocked,deferred,closed --limit 0 --json: Error: no beads database found`.
  The tracker gap appears twice, once as a leaked internal command.
- The ready verdict says `run ./scripts/nogg plan-begin to start`. That
  bypasses `./scripts/nogg worktree plan`, which the operating model
  requires before any OpenSpec write.
- `update` prints 102 `unchanged` lines and the same two `systemctl` hints
  every time. A preserved file is reported three times: in `Changed:`, under
  `Warnings:` and in the preserved block.
- Nothing checks `openspec`, `node`, `tmux` or an agent CLI before writing.
  `doctor` checks only `git`, `python3`, `bd` and `dolt` for presence.
- `scripts/bootstrap` prints its closing summary only in wizard mode. Its
  "Next" line suggests `./scripts/nogg doctor` although `doctor` has just
  run. It runs `doctor` a second time after `init`'s own verdict. Its
  platform refusal says "unsupported for 2.0.x".

**Verdict parsers.** `scripts/acceptance.sh` takes the last line matching
`Nogging is (ready|installed but not ready)`. In mechanical mode it requires
the gap text to be exactly ``uninitialized tracker (run `bd init`)``.
`scripts/release-smoke-test` greps `Nogging is ready`. `docs/acceptance.md`
step 3 quotes both lines.

**Release facts.** `v2.2.0` is `f7339c4`. `v2.2.0..develop` has 258 commits.
The archived changes since then are `add-herdr-session-backend`,
`harden-herdr-session-backend`, `launch-hook-fixes`,
`preserve-modified-verbatim-files`, `relaunch-on-orchestrator-restart`,
`usage-ledger-test-isolation` and `usage-visibility-fixes`. The live
changes `harden-planning-sessions`, `harden-session-supervision` and
`reliable-session-input` have only their acceptance tasks open.
`CHANGELOG.md` `[Unreleased]` is empty. Install pins are in `README.md`
(three), `docs/installation.md` (three) and `scripts/bootstrap`
(`NOGGING_TAG`). Hard-coded pin assertions are in
`scripts/installation-docs.test.sh`, `scripts/package-publication.test.sh` and
`scripts/nogging-identity.test.sh`. No CI job installs from the pinned tag.

## Goals / Non-Goals

**Goals:**

- A newcomer gets from the README's first screen to a running Lead session
  without opening another file. Reference material stays one link away.
- `init`, `update`, `remove` and `doctor` output is short enough to read,
  says what to do next, and never leaks an internal command.
- Install commands, flags, prerequisites and pins agree everywhere, and a
  test enforces it.
- `develop` is release-ready for `v3.0.0` except for steps the orchestrator
  owns (tag, push, GitHub Release, artifacts, smoke test).

**Non-Goals:** see `proposal.md`. In short: no new dependencies, no change to
what gets written, no gating preflight, no `doctor` line format change, and
no tag.

## Decisions

### 1. Shared discipline for every task

- **Tests run on GitHub runners.** No network, no `bd` or Dolt, no running
  tmux server, and no real `systemctl` or `loginctl`. Tools are PATH stubs
  in a temporary directory. Every new suite sources
  `scripts/lib/test-env.sh` and is picked up by `scripts/test`.
- **Zero new runtime dependencies.** `package.json` `dependencies` stays
  empty. Every new `bin/lib/*.js` module goes into `package.json` `files`.
  `scripts/package-manifest.test.sh` must stay green.
- **Verdict compatibility.** The first verdict line keeps its two shapes:
  `Nogging is ready — …` and `Nogging is installed but not ready: <gap>; <gap>`.
  Any extra line after it must not match
  `Nogging is (ready|installed but not ready)`.
- **No behaviour change to writes.** File classes, `.nogging-new`, `--force`
  with `.orig` backups, and the idempotence of `init` and `update` stay
  exactly as in the `installer` spec. Existing suites such as
  `scripts/cli.test.sh` and `scripts/manifest-legacy-upgrade.test.sh` may
  change only where they assert output wording.
- **Pins.** Until TASK-RRI-008, every install pin stays `v2.2.0`.

### 2. README for newcomers (TASK-RRI-001)

Top-level order. A structure test asserts it. `>` means "comes before":

1. Banner image (`docs/brand/nogging-banner.png`), `# Nogging`, the existing
   validation badge, and the tagline **Structure for a team of agents.**
2. **What Nogging is.** One paragraph of two or three sentences, before any
   `##` heading. It says that Nogging gives coding agents (Claude Code,
   Codex, Pi, Antigravity) a team structure: a Planning Agent writes the
   approved plan in OpenSpec, a Lead Agent executes it as Beads tasks with Git
   evidence, and a sync mirrors the evidence back. A single blockquote may
   follow. It states that Nogging is a public release and links `#safety-warning`.
3. `## Quick Guide`. At most eight numbered steps, each one line plus one
   command, from nothing to a closed first Bead: install, `doctor`, plan with
   `/plan`, `bd ready`, `session launch --role lead --bead <id>`,
   `session list` and `session log <name> --follow`, then close out with
   `/discovery-review` and `sync --now`. Each step links to its detailed
   section below. The quick-start diagram can sit here.
4. `## Install`, with `### Fresh machine (scripts/bootstrap)` and then
   `### Existing repository (npx init)`. It keeps the pinned curl one-liner,
   `--repo`, `--with-pi`, the wizard mention, the exact line
   `npx github:JoMe92/nogging#v2.2.0 init --no-systemd`, `doctor` and
   `validate`, and the rule "Always pin a tagged release, never
   `main`/`develop`". It keeps the `unscoped npm name` note, one line each
   for `update` and `remove`, and a link to `docs/installation.md`.
5. `## Use it day to day`, with four subsections in this order:
   - `### Plan a change`: `/plan` in Claude Code, or the supervised planner
     `session launch --role planning --planning-id <id> --description <desc>`.
     A compact manual sequence follows. It satisfies
     `scripts/planning-docs.test.sh`: commit as the `planning` writer before
     `materialize`, wire `bd dep add`, then `plan-end` from the planning
     worktree. `worktree cleanup` runs last, from the surviving canonical
     checkout, and the canonical planning lock is named.
   - `### Launch a Lead`: `bd ready`, `bd show <id>`, and the restricted
     `session launch --role lead --bead <id>`. `--full-access` appears only
     after a sentence that links
     the security and threat model (label "security and threat model",
     target `docs/security-model.md`, as in the existing README link).
   - `### Watch and steer sessions`: `session list`,
     `session log <name> --follow`, `session attach <name> --read-only`,
     `session watch`, `session send`/`nudge` and `session stop`. One
     sentence names the optional Orchestration Agent and links its section
     in `docs/operating-model.md`.
   - `### Close out`: the Lead commits with the `[<ID>]` token, then
     `bd close` and `task-done`, then the evidence note. The operator
     reviews the pull request, runs `sync --now` or relies on the timer,
     runs `/discovery-review`, and archives when `doctor` reports the
     change ready. Acceptance is a signed human report. The daily-workflow
     diagram can sit here.
6. After that, in this order: `## Safety warning` (shortened to at most two
   short paragraphs, keeping the risk statement and the link list),
   `## Project status and audience` (v3.0.0 is a **public release**; the
   section drops the "pre-public release candidate" wording and carries one
   note: keep target repositories where agents run with full access private,
   and read the safety warning before enabling `--full-access` or background
   services), `## Supported environments`,
   `## Concepts` (the two phases, the roles, the non-negotiable boundaries
   table, the communication-model and tool-map diagrams, links to
   `docs/vision-and-architecture.md`, `docs/operating-model.md` and
   `docs/architecture.md`), `## Documentation` (the existing table),
   `## Developing Nogging` (clone, `./scripts/install-hooks`, `scripts/test`,
   links to `CONTRIBUTING.md` and `docs/releasing.md`), and
   `## Inspiration and related projects`.

The CI job table moves to a `## Tests and CI` section in `CONTRIBUTING.md`,
unchanged except for links that need `../` adjustment. The README keeps
`scripts/test` and the badge. The `product-identity` requirement is updated
to match (spec delta).

**Check.** New `scripts/readme-structure.test.sh`, in Python, with no
network. It asserts:

- the head order (banner, `# Nogging`, badge, tagline);
- the intro paragraph has at most three sentence terminators;
- the `##` and `###` order above;
- the Quick Guide has at most eight numbered steps, and each contains a
  command;
- every install URL is pinned to a `v<semver>` tag, never `main` or
  `develop`;
- the security link comes before the first `--full-access`;
- the README no longer contains `pre-public` or `release candidate`, and
  the `## Project status and audience` section contains the private-
  repository note (`private`, `full access`, `safety warning`,
  `--full-access`, `background services`) and a link to `#safety-warning`;
- `## Tests and CI` exists in `CONTRIBUTING.md` and no longer in
  `README.md`;
- every relative link resolves to an existing file;
- every `#fragment`, in the README and in links to `docs/*.md#…`, matches a
  GitHub-style heading slug in its target.

Existing README suites are updated only where a heading moved or a line
wrapped. They keep the same assertions.

*Alternative considered:* a separate `docs/quick-guide.md`. Rejected: the PO
asked for the guide in the README, and one more hop is what newcomers miss.

### 3. Installer preflight (TASK-RRI-002)

New `bin/lib/preflight.js` exports a table and a `runPreflight(ctx)`.
Each table row has: the tool, how to read its version (argv plus a regex),
the minimum or supported line, `required` or `optional`, and the fix hint.

| Tool | Class | Minimum | Fix hint |
| --- | --- | --- | --- |
| Node.js | required | 18 (read from `process.versions.node`, no spawn) | upgrade Node, e.g. via nvm, or run the pinned `scripts/bootstrap` |
| Git | required | 2.30 | `sudo apt-get install git`, or the pinned `scripts/bootstrap` |
| Bash | required | 4.4 | `sudo apt-get install bash` |
| Python 3 | required | 3.9 | `sudo apt-get install python3` |
| OpenSpec CLI | required | 1.11 | `npm install -g @fission-ai/openspec@1.11` |
| bd (Beads) | required | 1.2 | the pinned `scripts/bootstrap`, or `docs/installation.md#prerequisites-in-the-target-repo` |
| Dolt | required | 2.3 | as for bd |
| tmux or herdr | optional | — | `sudo apt-get install tmux`; needed for supervised sessions |
| systemd user services | optional; skipped with `--no-systemd` | — | needed only for the sync timer and orchestrator service |
| Agent CLI (`claude`, `codex`, `pi`, `agy`) | optional; WARN when none is found | — | install at least one agent; link `docs/compatibility.md` |

The bootstrap hint is built from the package's own version:
`curl -fsSL https://raw.githubusercontent.com/JoMe92/nogging/v<version>/scripts/bootstrap | bash`.
No new pin is added that a release would need to bump.

Behaviour:

- It runs first in `init` and `update`, also under `--dry-run`, and prints a
  `Preflight` block. When every required tool passes, the block is one line,
  e.g. `Preflight: 7/7 required tools OK; optional: tmux, claude, codex`.
  Otherwise there is one line per problem, in the form
  `MISSING|TOO OLD|UNKNOWN <tool> (<found> < <min>) — fix: <hint>`.
- Each probe uses `spawnSync` with a timeout: 5 s by default,
  `NOGG_PREFLIGHT_TIMEOUT_MS` in tests. A timeout or an unreadable version
  is `UNKNOWN`. That is a warning, never a failure.
- It is advisory. It never changes the exit status, never blocks or changes
  a write, never installs, and never uses the network. `doctor` stays the
  authoritative check that feeds the verdict.
- It does not run for `remove` or `version`.

**Check.** New `scripts/installer-preflight.test.sh` with PATH stubs for
these cases:

- all tools present: the one-line summary;
- `openspec` missing: named, with the npm hint;
- `git` at 2.25: `TOO OLD` with its minimum;
- a stub that sleeps: `UNKNOWN` within the test timeout;
- no agent CLI: a WARN.

In every case the written tree is byte-identical, which the test confirms
with a manifest diff against an all-present run. The exit status stays 0.
`--dry-run` prints the preflight and writes nothing.

### 4. Grouped, summarized output (TASK-RRI-003)

New `bin/lib/report.js` replaces `report()` in `bin/cli.js` and renders
`ctx.log`, `ctx.warnings` and `ctx.notes`:

- **Header.** `Nogging <version> — init in <path>`. For update:
  `Nogging <old> → <new> — update in <path>`, or `(already at <version>)`.
  For remove: `Nogging — remove from <path>`. A dry run adds `(dry run)`.
- **Changes.** One line per file class, with counts per action: tool
  scripts, agent payloads (`.claude/`, `.codex/`, `.pi/`, `.agents/`,
  `.nogging/launch-*`), reference docs, scaffold, merged configuration,
  rendered units, and tracker and hooks. The class comes from the manifest
  entry that produced the log line, not from guessing at paths. Unchanged
  files are only counted. Each path appears once: when several entries log
  the same path, the most significant action wins, in the order
  `preserve` > `force-overwrite` > `create`/`update` > `keep` > `unchanged`.
- **`--verbose`** (new option on `init`, `update` and `remove`) adds the
  per-file list under each class. The full list is still available, but
  only on request.
- **Needs your review.** Each preserved file appears once, as
  `<path> — kept your edit; upstream in <path>.nogging-new`. This is
  followed by the two existing instructions: review and merge, or `--force`.
  The preserve warning no longer repeats under *Warnings*. A
  `--force` overwrite appears once, with its `.orig` backup.
- **Warnings** are deduplicated, in one block.

`ctx.log.entries` keeps its shape. `scripts/manifest-legacy-upgrade.test.sh`
asserts `ctx.warnings[0]` for the preserve case. It moves to the new
review-entry API in the same commit.

**Check.** New `scripts/installer-output.test.sh` runs these cases:

- fresh `init --no-beads`: the header, class counts, no path printed twice,
  output under 40 lines without `--verbose`;
- re-`init` and `update` with no change: an `unchanged` count and no file
  list;
- `update` after a local edit: exactly one mention in *Needs your review*;
- `update --force`: one `.orig` line;
- `remove --dry-run`: grouped output that writes nothing;
- `--verbose`: lists every manifest path once.

`scripts/cli.test.sh` is updated only for changed wording.

### 5. Next steps and the readiness verdict (TASK-RRI-004)

**Next steps** become a numbered block. Each item is one sentence plus its
command. Required items come first and optional items end with
`(optional)`.

- **`init`:**
  1. Resolve each verdict gap, e.g. `bd init` for an uninitialized tracker.
  2. `./scripts/nogg doctor`.
  3. Start the first plan: `/plan` in Claude Code, or
     `./scripts/nogg worktree plan <planning-id> <description>`. The Quick
     Guide is linked
     (`https://github.com/JoMe92/nogging/blob/v<version>/README.md#quick-guide`).
  4. Enable the sync timer, with the rendered unit path (optional).
  5. Enable the orchestrator service plus `loginctl enable-linger` (optional).
- **`update`:**
  1. Review each `.nogging-new` file, with the count.
  2. `./scripts/nogg doctor`.
  3. The unit hints, only for units that are not already enabled. This uses
     a best-effort `systemctl --user is-enabled <unit>` with a timeout. When
     the probe is unavailable, the hint is shown once with
     "if not already enabled".
- **`remove`:**
  1. `systemctl --user disable --now <unit>` for each rendered unit, before
     the checkout is deleted or moved.
  2. Review the shared `.gitignore` entries and Git hooks left behind.
  3. Commit the removal.

**Verdict.**

- The first line keeps its shapes (Decision 1). The ready line becomes
  `Nogging is ready — start your first plan with /plan or ./scripts/nogg worktree plan <planning-id> <description>.`
- Gaps are normalized and deduplicated. A `doctor` FAIL about a missing
  Beads database folds into ``uninitialized tracker (run `bd init`)``. A
  missing tool reads `<tool> not found`. Other FAIL text is kept but cut to
  its first clause, and never shows a command line built from internal
  arguments. The mechanical acceptance expectation (tracker as the only gap)
  then holds on a host that has `bd` installed but no database.
- Each gap is followed by an indented `fix:` line.
- `docs/acceptance.md` step 3 is updated to the new ready line.
  `scripts/acceptance.sh` and `scripts/release-smoke-test` still match it.
- **`npx … doctor`** runs `scripts/nogg doctor` once and captures its output.
  It prints the output unchanged, then the same verdict and the `init`
  next-step items 1–3. It exits with `doctor`'s status.

**Check.** New `scripts/installer-next-steps.test.sh` covers:

- `init` with a stub `bd` lacking a database: the tracker is the only gap,
  with no leaked `bd list` text;
- the item order, with required items before optional ones;
- `--no-systemd` drops the unit items;
- `update` with a stub `systemctl` reporting the timer as enabled: no timer
  hint;
- `remove`: the disable items name the rendered units;
- the `doctor` wrapper's exit status equals the stub `doctor`'s;
- the ready line still matches `scripts/release-smoke-test`'s grep.

### 6. Bootstrap plan and closing summary (TASK-RRI-005)

- **Plan block.** After the platform gate, and in wizard mode after the
  wizard choices, bootstrap prints `Plan for <repo> (Nogging <tag>)`. One
  line per tool follows, in the form `present <version>`,
  `install <pin>` or `upgrade <have> → <pin>`. The lines come from the
  existing version checks, split into a side-effect-free `plan_*` probe and
  the existing `ensure_*` installer, which does the same comparison.
  Nothing is installed before the block is printed.
- **Platform refusal.** It names the supported set from
  `docs/compatibility.md` without a release number.
- **`doctor` once.** Bootstrap passes `init`'s verdict through. `init` runs
  its own readiness check internally. Bootstrap then runs
  `./scripts/nogg doctor` itself exactly once, captures it, and shows only
  its `FAIL` and `WARN` lines plus one result line. The full report goes to
  `<repo>/.nogging/state/bootstrap-doctor.log`, which the result line names.
  The exit status is still `doctor`'s.
- **Closing summary in both modes.** It is plain text on stdout. In wizard
  mode the same text also goes into the whiptail message box. It lists the
  tools installed or upgraded, those already present, and those skipped.
  It shows login status for `gh`, `claude` and `codex`, using the existing
  read-only `check_*_auth` probes: `logged in`, or
  `not logged in — run <command>`. It never reads or prints a credential.
  Then come the next steps: `cd <repo>`, any verdict gap fix, the first plan
  (`/plan` or `./scripts/nogg worktree plan …`), and the optional timer.
  `doctor` is listed only when it reported a problem.
- Flags, help text and the piped non-interactive path are otherwise
  unchanged. The script stays POSIX `sh`.

**Check.** New `scripts/bootstrap-summary.test.sh` sources the script with
`NOGGING_BOOTSTRAP_NO_MAIN=1` and stubs every command. It checks:

- `plan_*` output for present, missing and out-of-range tools, with no
  install command invoked;
- the summary text in non-interactive mode, including the logged-out hint;
- the platform refusal has no `2.0.x`;
- `doctor` is invoked exactly once by `run_nogging_init`;
- no credential-shaped stub output reaches stdout.

`scripts/bootstrap-wizard.test.sh` and `scripts/compatibility.test.sh` stay
green.

### 7. Version level and changelog backfill (TASK-RRI-006)

**Version: `3.0.0` (major).** Since `v2.2.0`, three changes break documented
behaviour that an existing installation or its automation relies on:

1. **`update` keeps locally modified managed files** (#165,
   `preserve-modified-verbatim-files`). It writes `<file>.nogging-new`
   instead of overwriting. Automation that ran `update` to reset local edits
   now keeps them, unless it passes `--force` (which writes `.orig` backups).
2. **Codex and Antigravity planning launches without `--profile` or
   `--full-access` are refused before any side effect**
   (`harden-planning-sessions`, TASK-HPS-004). A command line accepted by
   `v2.2.0` now exits non-zero.
3. **Reservation-ledger entries are backend-neutral and versioned**
   (`add-herdr-session-backend`, `usage-ledger-test-isolation`). A `v2.2.0`
   reader crashes on them with `KeyError: 'tmux'`. The documented rollback,
   "run `update` from the exact preceding tag", is therefore safe only after
   every reservation is released (`docs/failure-recovery.md`).

The project set its own precedent in `2.0.0`: a major bump when behaviour
that installations relied on changes. The changes in `2.1.0` and `2.2.0`
were different in kind. They tightened defaults that had not worked as
intended (the `trusted` `defaultMode`) or refused work that could not have
succeeded (launches with unmet dependencies). Item 3 breaks the documented
rollback path, and item 2 breaks working scripted Antigravity launches, so
`2.3.0` would understate the upgrade risk. *Alternative considered:*
`2.3.0` with the three items only under "Changed". Rejected for that reason.

**Backfill.** Fill `[Unreleased]` from `git log v2.2.0..develop`, the archived
and live changes listed in *Context*, and their `proposal.md` files:

- Use Keep a Changelog sections (`Added`, `Changed`, `Fixed`, `Removed`).
  Write one bullet per user-visible capability, in the existing style: a
  bold lead-in, then what it means for a user.
- Leave out test-only, sync-mirror, OpenSpec-planning and acceptance-report
  commits, unless a user-visible behaviour came with them.
- The three items above are `**BREAKING**` bullets at the top of `Changed`.
  Each names its migration: `update --force`; `--profile trusted`,
  `--profile restricted` or `--full-access`; release all reservations, or
  wait for active sessions to end, before rolling back to `v2.2.0`.
- Add an `Upgrade notes` paragraph at the top of the section. It covers
  running `update` from the new tag, reviewing `.nogging-new` files, and
  the rollback caveat.
- Do not add the version heading. TASK-RRI-008 cuts it.

**Check.** New `scripts/changelog-format.test.sh` validates the structure:

- exactly one `## [Unreleased]`, at the top;
- every other section is `## [X.Y.Z(-rc.N)] - YYYY-MM-DD`, with strictly
  descending versions;
- only Keep a Changelog subsection names;
- a released section that contains `**BREAKING**` has a higher major than
  the next older released section. This guard catches a mislabelled
  release.

The Bead note lists each archived and live change and the bullet that
covers it.

### 8. One install surface (TASK-RRI-007)

After the README, the CLI and the bootstrap work have landed:

- `docs/installation.md` documents the preflight (table and advisory rule),
  the grouped output and `--verbose`, the next-step blocks, the verdict with
  `fix:` lines, the `doctor` wrapper and the bootstrap plan and summary. It
  uses the same wording as the CLI help for each flag. Its prerequisites list
  matches the preflight table: names, minimums, required or optional.
- `bin/cli.js` help is reworded where needed. Every command and option has
  one line, the same phrase is used across surfaces, and help ends with a
  pointer to `docs/installation.md` and the pinned bootstrap.
- **Pins derive from `package.json`.** The hard-coded `v2.2.0` assertions in
  `scripts/installation-docs.test.sh`, `scripts/package-publication.test.sh`,
  `scripts/nogging-identity.test.sh` and, if present,
  `scripts/readme-structure.test.sh` read `v$(node -p "require('./package.json').version")`.
  New `scripts/release-pins.test.sh` asserts that every
  `github:JoMe92/nogging#…` and `raw.githubusercontent.com/JoMe92/nogging/…`
  reference in `README.md` and `docs/installation.md`, and `NOGGING_TAG` in
  `scripts/bootstrap`, equal `v<package version>`. A `<tag>` or `<new-tag>`
  placeholder is allowed. A bare `main` or `develop` is not.
- `docs/releasing.md` step 4 names `scripts/bootstrap` (`NOGGING_TAG`) and
  says `scripts/release-pins.test.sh` proves the bump is complete.

**Check.** New `scripts/install-surface-consistency.test.sh` checks that:

- every option in `bin/cli.js --help` is documented in
  `docs/installation.md`, and every installation-guide flag exists in the
  CLI help or the bootstrap usage;
- every bootstrap usage flag is documented under the bootstrap section;
- the prerequisites list equals the preflight table;
- the README install commands appear verbatim in `docs/installation.md`.

`scripts/release-pins.test.sh` is the other new suite. Both pass at
`v2.2.0` and would fail on a partial bump.

### 9. Release preparation (TASK-RRI-008)

Follow `docs/releasing.md` steps 2–5 for `3.0.0` on a branch from updated
`develop`:

1. Add `[Unreleased]` bullets for this change's user-visible work: the
   README, the installer preflight, the grouped output and `--verbose`, the
   next steps and verdict, and the bootstrap plan and summary. Add bullets
   for anything merged after TASK-RRI-006. Then rename the section
   `## [3.0.0] - <commit date>` and open a fresh, empty `## [Unreleased]`
   above it.
2. Set `package.json` to `3.0.0` and refresh `package-lock.json` with
   `npm install --package-lock-only`. Both top-level `version` fields must
   read `3.0.0`, with no dependency change. Where the registry is
   unreachable (for example in a sandboxed session), set the two top-level
   fields (`version` and `packages[""].version`) directly instead. The
   lockfile diff must then touch only those two lines.
3. Bump every install pin from `v2.2.0` to `v3.0.0` in `README.md`,
   `docs/installation.md` and `scripts/bootstrap` `NOGGING_TAG`. Historical
   mentions of `v2.2.0` stay: the rollback caveat, the ledger fixture and
   the baselines.
4. Commit as `chore(release): prepare v3.0.0 [<Bead ID>]`.
5. Run `scripts/release-check 3.0.0`. Every line is `OK`, and the tag line
   reads "does not exist yet". Run `scripts/release-pins.test.sh`,
   `scripts/changelog-format.test.sh` and `scripts/test`.

No tag, no tag push and no GitHub Release. The Bead note hands steps 6–11 to
the orchestrator.

## Dependencies and parallel lanes

`A ← B` means A depends on B (`bd dep add A B`). The edges are explicit, not
inferred from task order. Branches follow `<type>/release-readme-installer`.
Each lane owns one prefix. Tasks in the same lane run one after another, and
each deletes its integrated branch before the next allocates it. The prefix
only tells parallel worktrees apart. Each commit subject keeps its own
Conventional type.

| Task | Complexity | Depends on | Branch prefix | Main files (ownership) |
| --- | --- | --- | --- | --- |
| RRI-001 README for newcomers | standard | — | `docs/` | `README.md`, `CONTRIBUTING.md`, `scripts/readme-structure.test.sh`, README assertions in existing suites |
| RRI-002 installer preflight | standard | — | `feat/` | new `bin/lib/preflight.js`, `bin/cli.js` (call site), `package.json` `files`, `scripts/installer-preflight.test.sh` |
| RRI-003 grouped output | standard | 002 | `feat/` | new `bin/lib/report.js`, `bin/cli.js` (`report`, `--verbose`), `bin/lib/fsops.js`, `bin/lib/install.js` (log classes), `scripts/installer-output.test.sh` |
| RRI-004 next steps and verdict | standard | 003 | `feat/` | `bin/lib/install.js` (`readinessVerdict`, `beadsHint`), `bin/lib/systemd.js`, `bin/lib/remove.js`, `bin/cli.js` (`cmdDoctor`), `docs/acceptance.md` step 3, `scripts/installer-next-steps.test.sh` |
| RRI-005 bootstrap plan and summary | standard | — | `fix/` | `scripts/bootstrap`, `scripts/bootstrap-summary.test.sh` |
| RRI-006 changelog backfill | standard | — | `chore/` | `CHANGELOG.md` (`[Unreleased]`), `scripts/changelog-format.test.sh` |
| RRI-007 one install surface | standard | 001, 004, 005 | `test/` | `docs/installation.md`, `docs/releasing.md`, `bin/cli.js` (help text only), pin assertions in four suites, `scripts/install-surface-consistency.test.sh`, `scripts/release-pins.test.sh` |
| RRI-008 release prep v3.0.0 | routine | 001, 005, 006, 007 | `chore/` | `CHANGELOG.md`, `package.json`, `package-lock.json`, install pins in `README.md`, `docs/installation.md`, `scripts/bootstrap` |

Why each edge exists:

- **003 ← 002, 004 ← 003.** All three edit `bin/cli.js` and
  `bin/lib/install.js`. The report renderer prints the preflight block, and
  the next steps and verdict are rendered by the report module.
- **007 ← 001.** It aligns the README install commands and edits the README
  pin assertion in `scripts/nogging-identity.test.sh`.
- **007 ← 004, 005.** The installation guide documents the final CLI and
  bootstrap output.
- **008 ← 006.** The release cuts the backfilled `[Unreleased]` section and
  continues the `chore/` lane.
- **008 ← 001, 005, 007.** It bumps pins in files those tasks own. It relies
  on `scripts/release-pins.test.sh` (007) to prove the bump complete. Its
  changelog bullets describe their final behaviour. 008 also waits for 004,
  transitively through 007.

The lanes run as follows:

- **At start:** 001 (`docs/`), 002 (`feat/`), 005 (`fix/`) and 006
  (`chore/`) can all begin at once. Their files do not overlap.
- **Spines:** 002 → 003 → 004 on `feat/`; then 007 on `test/`; then 008 on
  `chore/`.

**Cross-change overlap, no edge.** TASK-HPS-007, TASK-HSS-008 and
TASK-RSI-009 write only `docs/acceptance/<date>-*.md`. Whichever lands
second rebases. If one of them merges after TASK-RRI-006, TASK-RRI-008 checks
it for a user-visible change and adds a bullet if there is one.

Before allocating a dependent worktree, a Lead verifies that every
prerequisite execution commit is integrated into `develop`. Bead closure
alone is not enough. Every task suits a sandboxed Codex or Claude Lead. A
restricted Codex Lead needs `--profile trusted` or `--full-access` to reach
the shared Dolt server.

## Risks / Trade-offs

- **README contract churn.** Five suites assert README text. The rewrite
  keeps the asserted phrases and changes only the location checks, in the
  same commit. Review checks that no assertion was weakened.
- **Verdict parsers.** Changing the ready line could break
  `scripts/acceptance.sh` or `scripts/release-smoke-test`. Both match only
  the stable prefix, and Decision 5's check pins that.
- **Probe latency.** Seven to ten `--version` spawns add about a second to
  `init`. Timeouts bound a hung tool. This is accepted for a one-off
  command.
- **systemd probe on `update`.** `systemctl --user is-enabled` can be absent
  or slow (containers, CI). It is best effort with a timeout and falls back
  to the hint, so it never fails.
- **Changelog accuracy.** A 258-commit backfill can miss or overstate items.
  The coverage list in the Bead note and the PR review are the safeguard.
  The `**BREAKING**` guard in `changelog-format.test.sh` keeps the major
  bump consistent.
- **Major version perception.** `3.0.0` may suggest a larger change than
  users see. The upgrade notes say plainly which three behaviours changed
  and that everything else is additive.
- **Pins ahead of the tag.** After TASK-RRI-008 merges, `develop` documents
  `v3.0.0` before the orchestrator creates the tag. This matches the
  documented release order (steps 4 to 7), and no CI job installs from the
  pin.
