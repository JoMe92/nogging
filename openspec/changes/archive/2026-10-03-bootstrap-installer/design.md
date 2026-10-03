# Design — one-command bootstrap installer

## Decision 1 — a standalone shell script, not an `npx` subcommand

The existing installer is reached via `npx github:JoMe92/nogging init`,
which requires Node to already exist. A true "one command on a fresh
machine" entry point cannot assume that — it may need to *install* Node
itself. So `scripts/bootstrap` is a plain POSIX-compatible shell script,
fetchable and runnable with nothing but `curl`/`wget` and `bash`
(`curl -fsSL <raw-url>/scripts/bootstrap | bash`), matching the established
pattern other ecosystem installers (`nvm`, `rustup`, Dolt's own, Beads' own)
already use. Node only becomes a requirement partway through the script's
own run, at the point it starts installing npm-distributed tools — by then
the script has provisioned it itself via `nvm` (Decision 2).

`curl | bash` carries a known trust cost (arbitrary code execution from a
URL). This change accepts it as the standard, already-expected shape for
this category of installer, and mitigates it the standard way: the one-liner
documented in `README.md`/`docs/installation.md` always pins a tagged
release URL (`.../nogging/<tag>/scripts/bootstrap`), never `main`/`develop`,
so what a user runs is reviewable, reproducible, and matches a signed Git
tag rather than a moving branch.

## Decision 2 — Node via `nvm`, not a system package manager

`nvm` installs into the invoking user's home directory, needs no `sudo`, and
is already the de facto standard way this project's own hosts provision
Node (confirmed in active use here). A NodeSource+`apt` alternative would
need `sudo` earlier in the script and modifies system package sources —
more invasive for the same result. `scripts/bootstrap` installs `nvm` itself
(via its own official installer, pinned to a specific `nvm` release) only if
not already present, then `nvm install <pinned-LTS>` using the compatibility
baseline's current validated line.

## Decision 3 — orchestrate each tool's own official installer, pinned

Rather than Nogging re-implementing architecture detection and binary
download/checksum logic for `bd` and `dolt`, `scripts/bootstrap` calls each
project's own install script at an **exact pinned release tag** — e.g.
`https://github.com/dolthub/dolt/releases/download/v2.3.1/install.sh`, not
`.../releases/latest/download/install.sh` — confirmed reachable (HTTP 200)
for both `dolt` and `bd` during planning. This means:

- Architecture/OS detection for these two tools is the upstream project's
  own, already-audited logic, not a second implementation Nogging has to
  keep correct across every future `bd`/`dolt` release.
- A version bump is a one-line pin change in `scripts/bootstrap`, verified
  by the pin-consistency test (Decision 5), not a logic change.
- `bd`'s own install script already verifies release checksums; `dolt`'s
  downloads from a tag-pinned GitHub Releases asset, which is itself
  integrity-checked by GitHub's own release/CDN infrastructure.

The three Node-ecosystem CLIs (`claude`, `codex`, `openspec`) are simpler:
`npm install -g <package>@<pinned-version>` is npm's own standard pinning
mechanism, requiring nothing bespoke.

## Decision 4 — idempotent, version-checking, not blindly reinstalling

Before installing anything, `scripts/bootstrap` checks whether it is already
present at a version satisfying the pin (`<tool> --version` or equivalent,
matched against the compatibility baseline's range, not requiring an exact
patch match — `docs/compatibility.md` itself distinguishes a "validated"
version from the wider "supported" range, e.g. Beads `1.2.x`). A satisfying
existing install is left alone and reported, not reinstalled; a missing or
out-of-range one is installed/upgraded to the pin. This makes the script
safe to re-run (e.g. after a partial failure, or periodically to confirm a
machine still matches the baseline) rather than something run exactly once.

## Decision 5 — one source of truth, enforced by a test

`docs/compatibility.md` stays the prose source of truth for which versions
are validated — this change does not introduce a second, machine-readable
version manifest that could drift from it. Instead, `scripts/bootstrap`'s
own pins are checked by a new test (mirroring `scripts/compatibility.test.sh`'s
existing role) that parses both the script's pinned version strings and
`docs/compatibility.md`'s table and fails if they disagree. A version bump
that updates one without the other is caught by `scripts/test`, not
discovered later by a user getting an unvalidated combination.

## Decision 6 — platform gate fails loudly, first

The very first thing `scripts/bootstrap` does is check `/etc/os-release` (or
equivalent) against the supported Debian/Ubuntu-family set and the running
architecture against x86_64/aarch64. On a mismatch it prints exactly what
`docs/compatibility.md` already states — which platforms are supported, and
that this one is not — and exits before attempting anything, rather than
partially provisioning a machine `doctor` would later report as broken in
ways neither the user nor this script expected.

## Non-goals

- No macOS/Windows/WSL path (`proposal.md`).
- No change to `npx github:JoMe92/nogging init`'s own behavior — this change
  adds a layer in front of it, it does not modify what `init` does once
  reached.
- No change to `docs/compatibility.md`'s pinned versions themselves — this
  change automates installing to the pins that already exist.
