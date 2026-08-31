# Design

## Context

SpecForge's structure is a fixed set of files plus one host-specific rendered
unit. Installing it elsewhere is a file-placement problem with four distinct
strategies, not a package-management problem. The user chose `npx` distribution
from a private GitHub repository; `npx github:JoMe92/specforge` clones the repo
over the existing `gh` HTTPS credential and runs its `bin`, so no npm-registry
publish and no build step are involved. The installer must be zero-dependency
so that `npx` is fast and works with only Node present.

## Goals / Non-goals

- Goal: `npx github:JoMe92/specforge init` installs the full structure into the
  current git repository in one command.
- Goal: `update` pulls later tool-file fixes without disturbing target-owned
  planning/execution state.
- Goal: every foreign-file edit is idempotent and reversible by hand.
- Non-goal: installing or initializing `bd`, `dolt`, `python3`, or the systemd
  timer itself — the installer only writes files and prints next steps.
- Non-goal: publishing to npm, or supporting non-git target directories.
- Non-goal: editing `openspec/` in this planning session or materializing Beads.

## Decisions

### Distribution: `npx github:` from a private repo

The install command is `npx github:JoMe92/specforge init` (optionally
`#<tag>`). `package.json` gains `"bin": {"specforge": "bin/cli.js"}`, a `files`
whitelist covering `bin`, `templates`, `scripts`, `.agents`, `docs` and
`openspec/config.yaml`, `"engines": {"node": ">=18"}`, `"main": "bin/cli.js"`
and a real `description`. No `"type": "module"` — the CLI is CommonJS so
`__dirname` and `require('../package.json')` are trivial. The payload source at
runtime is the CLI's own package root (`path.join(__dirname, '..')`); this repo
stays self-hosting with no duplicated `template/` tree.

Auth fallback for documentation: if `git` does not hand the token to the
`npx github:` clone, the target runs `gh auth setup-git` once, or uses the SSH
form `npx github:JoMe92/specforge`.

### File classes and the manifest

`bin/lib/manifest.js` exports four lists consumed by `bin/cli.js`:

| Class | Members | `init` | `update` |
| --- | --- | --- | --- |
| verbatim | `scripts/specforge`, `scripts/install-hooks`, `scripts/test`, `scripts/specforge.test.sh`, `scripts/hooks/{commit-msg,pre-commit,pre-tool-use-openspec-guard,commit-msg.test.sh}`, `.agents/skills/**`, `docs/specforge/{operating-model,architecture,failure-recovery}.md` | overwrite | overwrite |
| scaffold | `openspec/config.yaml`, `openspec/project.md` (from `templates/openspec-project.md`), `.specforge/config.json` (from `templates/specforge-config.json`, `name` = repo basename) | write if absent | skip |
| merge | `.claude/settings.json`, `.gitignore`, `CLAUDE.md`, `AGENTS.md` | idempotent merge | idempotent merge |
| rendered | `systemd/specforge-sync-<slug>.service`, `…​.timer` | render | render |

The reference docs land under `docs/specforge/` (not `docs/`) so they never
clobber a target's own docs. `bin/lib/fsops.js` does dry-run-aware
copyFile/copyDir/ensureDir and returns a change log for the final report.

### Merge semantics (`bin/lib/merge.js`)

- **`.claude/settings.json`**: parse JSON (empty/absent → `{}`), ensure
  `hooks.PreToolUse` contains an entry whose `matcher` is `"Edit|Write"` and
  whose command string contains `pre-tool-use-openspec-guard`; insert only if no
  such entry exists. Preserve every other key. Write back with 2-space indent
  and trailing newline. The existing `SessionStart` `bd prime` hook, if present,
  is untouched.
- **`.gitignore`**: append any of `.specforge/locks/`, `.specforge/state/`,
  `.specforge/reports/`, `__pycache__/`, `*.py[cod]` that is not already a
  line, under a `# SpecForge` comment, once.
- **`CLAUDE.md` / `AGENTS.md`**: maintain a block delimited by
  `<!-- specforge:begin -->` / `<!-- specforge:end -->`. On `init`/`update`,
  replace the block content if the markers exist, else append the block (from
  `templates/claude-block.md` / `templates/agents-block.md`). Create the file
  with just the block if absent. Content outside the markers is never touched.

### systemd rendering (`bin/lib/systemd.js`)

Slug = repo basename lowercased, non-alphanumeric → `-`, collapsed. Templates
`templates/systemd/specforge-sync.service.tmpl` and `…​timer.tmpl` use
`{{WORKDIR}}` and `{{SLUG}}` / `{{NAME}}`. The service `ExecStart` is
`{{WORKDIR}}/scripts/specforge sync`; `WorkingDirectory={{WORKDIR}}`;
`Description` includes `{{NAME}}`. Enable instructions printed by the installer:
`systemctl --user enable --now "$PWD/systemd/specforge-sync-<slug>.timer"`
(absolute path — `systemctl --user enable` links it into the user unit dir).

### `update` and version tracking

`update` refuses if `.specforge/config.json` is absent (tells the user to run
`init`). It re-runs the verbatim + merge + rendered steps, skips the scaffold
step entirely, and sets `.specforge/config.json.specforge_version` to
`require('../package.json').version`. It never reads or writes
`openspec/changes/**` or `openspec/project.md`. `init` also writes
`specforge_version`.

### Post-write steps in `init`

1. `chmod 0755` on `scripts/specforge`, `scripts/install-hooks`, `scripts/test`,
   `scripts/hooks/*` (the `.test.sh` files are run via `bash <file>` so mode is
   cosmetic there).
2. Unless `--no-hooks`: run the installed `scripts/install-hooks`. First read
   `git config --get core.hooksPath`; if set and not `.git/hooks`, skip the
   install and print the boundary-hooks warning (this is the known Beads
   collision — Beads points `core.hooksPath` at `.beads/hooks`).
3. Unless `--no-systemd`: write the rendered units and print the enable line.
4. If `.beads/` is absent, print a `bd init` hint (do not run it).
5. Print the change log and a "next steps" block.

Flags: `--force` (allow `init` over an existing install), `--dry-run` (print the
change log, write nothing), `--no-hooks`, `--no-systemd`.

### `doctor` passthrough and `python3` check

`bin/cli.js doctor` execs `scripts/specforge doctor` in the cwd if present, else
errors with a hint to run `init`. Separately, `scripts/specforge` `doctor` gains
`python3` in its tool-availability loop next to `git`, `bd`, `dolt`.

## Risks / open questions

- `npx github:` against a private repo depends on the local git credential
  helper serving the token to the clone; documented fallback is
  `gh auth setup-git` or the SSH URL form.
- The `PreToolUse` guard and the two git hooks only bind where Git reads
  `.git/hooks`; when `core.hooksPath` is redirected the installer warns but
  cannot fix it. Reconciling the two hook paths is already tracked as a
  discovery on SPEC-7ec and is out of scope here.
- Node >= 18 is assumed in target repos for the one-off install; `engines` is
  advisory, `npx` will still run on older Node with a warning.
