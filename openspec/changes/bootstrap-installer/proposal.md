# One-command bootstrap installer

## Source

Product Owner request (not a GitHub issue — checked first: no open or closed
issue covers this). Today, `npx github:JoMe92/nogging init` installs the
Nogging *payload* into an already-prepared repository, but it assumes Node,
Claude Code, Codex, OpenSpec CLI, `bd` (Beads), Dolt, `git`, and `tmux` are
already present — `scripts/nogg doctor` only *checks* for them
(`docs/compatibility.md` documents the pinned, validated version of each),
it installs none of them. Setting up a fresh machine today means manually
installing six-plus separate tools in the right versions before Nogging's own
installer can even be run meaningfully. The ask: one command that provisions
the whole stack, versions pinned, on a fresh machine.

## Research performed

- Read `docs/compatibility.md` directly: the version pins the Product Owner
  wants already exist and are already the project's documented contract —
  Node 18/20/22, OpenSpec CLI 1.11.x (validated 1.11.0), Beads 1.2.x
  (validated 1.2.2), Dolt 2.3.x (validated 2.3.1), Claude Code validated
  2.1.260, Codex CLI validated 0.148.0, Pi 0.85.0 (optional, needs Node
  22.19+). What's missing is automation that *acts* on these pins, not the
  pins themselves.
- Inspected how each tool is actually installed on this host, rather than
  guessing: `claude`, `codex`, and `@fission-ai/openspec` are global npm
  packages (`@anthropic-ai/claude-code`, `@openai/codex`,
  `@fission-ai/openspec`); `bd` and `dolt` are standalone Go binaries under
  `/usr/local/bin`, installed independently of npm.
- Confirmed both `bd` and `dolt` ship **official, maintainer-provided install
  scripts that can be pinned to an exact release tag** rather than always
  resolving "latest": `https://github.com/dolthub/dolt/releases/download/v2.3.1/install.sh`
  and `https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh`
  (HTTP 200 on both pinned forms, checked directly). Beads' own script
  additionally verifies release checksums.
- Decided, on this basis, **not** to reimplement binary downloads or
  architecture detection in a new Nogging-authored installer: orchestrate
  each tool's own official, already-audited installer at a pinned version
  instead. This is less code, less to maintain as upstream releases change
  their asset layout, and strictly safer than a second, parallel download
  path.
- Confirmed `nvm` is a viable, already-precedented way to provision Node
  without `sudo` or touching system package sources (observed in active use
  on this very host) — preferred over a NodeSource+`apt` approach for that
  reason.
- Re-read `docs/compatibility.md`'s own platform table: supported is
  **Debian/Ubuntu-family Linux, x86_64 and aarch64** only; macOS, Windows,
  and WSL are explicitly "Unsupported for 2.0.x." This change targets exactly
  that already-committed boundary — it does not expand platform support, it
  automates provisioning within it.

## Why

A fresh-machine setup today is six-plus separate manual installs before
`npx github:JoMe92/nogging init` is even reachable, each a place to get a
version wrong relative to what's actually validated. A single, pinned,
idempotent bootstrap turns "read six tools' install docs and hope the
versions line up" into one command with one source of truth.

## What Changes

- **`scripts/bootstrap`** — a new, standalone shell script (no Node
  required to start it, since it may need to *install* Node) that:
  1. Verifies the host is a supported platform (Debian/Ubuntu-family Linux,
     x86_64 or aarch64) and refuses clearly, not silently, otherwise.
  2. Provisions Node via `nvm`, pinned to the compatibility baseline's LTS
     line, if not already present at a satisfying version.
  3. `npm install -g` the pinned versions of `@anthropic-ai/claude-code`,
     `@openai/codex`, and `@fission-ai/openspec`; `@earendil-works/pi-coding-agent`
     only behind an explicit `--with-pi` flag (optional path, stricter Node
     floor).
  4. Runs `bd`'s and `dolt`'s own official install scripts, each pinned to
     the compatibility baseline's exact release tag, not "latest."
  5. Ensures `git`, `tmux`, and `gh` are present (via the system package
     manager where missing — clearly prompting for the `sudo` it needs, not
     silently).
  6. Runs `npx github:JoMe92/nogging@<pinned-tag> init` against the target
     repository (default: current directory; creates and `git init`s it
     first if it does not exist yet, when a `--repo <path>` is given for a
     brand-new location).
  7. Runs `scripts/nogg doctor` and prints a clear final pass/fail summary.
  - **Idempotent**: re-running it checks each tool's installed version
    against the pin first and skips a step that is already satisfied,
    rather than reinstalling unconditionally.
- **One documented one-liner** in `README.md` and `docs/installation.md`:
  `curl -fsSL https://raw.githubusercontent.com/JoMe92/nogging/<tag>/scripts/bootstrap | bash`.
- **A pin-consistency test** asserting `scripts/bootstrap`'s hardcoded
  version pins match the versions `docs/compatibility.md` documents, so the
  two cannot silently drift apart.

## Out of scope

- **macOS, Windows, WSL.** `docs/compatibility.md` already scopes these as
  unsupported for 2.0.x; extending the bootstrap there is a separate,
  larger follow-up that would need its own platform evidence, not a
  side effect of this change.
- **Pi CLI by default.** Opt-in via `--with-pi` only — it is documented
  throughout as the optional path with the stricter Node requirement.
- **Upgrading already-installed tools to a newer pin later.** This change
  delivers first-install provisioning; a `bootstrap --upgrade` path that
  moves an existing install to a newer pinned version is a reasonable
  follow-up, not required for the one-command *setup* this change targets.
- **A hosted, Nogging-controlled download mirror for `bd`/`dolt`/npm
  packages.** This change deliberately depends on each upstream project's
  own release infrastructure rather than building a second one.
