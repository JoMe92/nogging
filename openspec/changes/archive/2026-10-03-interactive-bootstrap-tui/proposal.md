# Interactive bootstrap wizard

## Source

Product Owner request, not a GitHub issue — checked first: no open or closed
issue or Bead covers an interactive/TUI/wizard installer. `scripts/bootstrap`
(shipped in `bootstrap-installer`, already merged) exists and works, but runs
fully non-interactively with fixed defaults. The ask: a Nogging-styled,
interactive terminal experience — the user decides yes/no on each component
and the install path, and gets prompted to log into whichever of
Claude Code / Codex / GitHub isn't authenticated yet, all from the same
guided flow.

## Research performed

- **Login-status checks, verified directly against each installed CLI on
  this host**, not assumed:
  - `gh auth status` — clean exit code and text, `gh auth login` to
    authenticate.
  - `codex login status` — same pattern exactly (`"Logged in using ChatGPT"`,
    exit 0), `codex login` to authenticate.
  - Claude Code has no equivalent status subcommand; the closest reliable,
    non-interactive proxy is the presence of `~/.claude/.credentials.json`.
    There is no one-shot non-interactive login either — running `claude`
    itself triggers the first-run browser OAuth flow interactively.
- **TUI mechanism**: `whiptail` (Debian package `whiptail`) ships on
  Debian/Ubuntu — Nogging's already-supported platform for `scripts/bootstrap`
  — and gives real dialog/yesno/checklist/inputbox widgets from plain Bash,
  with no Node dependency, fitting `scripts/bootstrap`'s existing "must run
  before Node exists" constraint. Compared against `rustup`'s own installer,
  which deliberately uses only plain colored `read` prompts for maximum
  portability across platforms it supports beyond Nogging's own narrower,
  already-committed scope — the Product Owner was shown both styles directly
  (a whiptail-dialog mockup and a plain-prompt mockup) and chose whiptail.
- **Brand research**: no machine-readable color palette exists in this repo
  (the full brand style guide lives in the private `JoMe92/rooftree`
  companion repo per `docs/brand/`'s own history); read `docs/brand/nogging-logo.png`
  directly instead — dark forest green and sage green, a timber-framing
  motif (vertical "studs" crossed by horizontal "nogging" braces — literally
  illustrating the term the project is named for), lowercase wordmark,
  tagline "structure for what's next." in tracked small caps.

## Why

A fresh install today is either `npx ... init` (needs Node already) or
`scripts/bootstrap` (fully automated, no choices, no login help) — both
correct, but neither lets a Product Owner see and decide what's about to
happen, or get walked through authenticating the tools Nogging actually
needs. A guided, on-brand terminal experience is squarely what a "structural
layer" product's own first five minutes should look like.

## What Changes

- `scripts/bootstrap` gains an **interactive mode**: the default when both
  stdin and stdout are a TTY and `whiptail` is present or can be installed;
  falls back to today's fully-automated, non-interactive behavior otherwise
  (CI, piped input, `--non-interactive` passed explicitly) — **unchanged for
  every existing caller**, interactive mode is additive, not a replacement.
- A welcome screen (ASCII Nogging wordmark + tagline, dark-green/sage-green
  ANSI coloring approximating the logo) and a Yes/No confirmation before
  anything is installed.
- An install-path dialog (default: current directory or `--repo` if given;
  offers to create and `git init` a new location).
- An optional-components checklist (Pi agent support, systemd sync timer,
  git hooks, Beads init) mapping directly onto flags `scripts/bootstrap`/
  `init` already accept — the checklist's default checked/unchecked state
  matches today's actual defaults exactly.
- An authentication step: for each of GitHub, Claude Code, and Codex, check
  status (per the verified mechanism above); if not authenticated, ask
  Yes/No to log in now, and if yes, hand the terminal to that tool's own
  login flow (`gh auth login`, `codex login`, or `claude` once) — Nogging
  never asks for or handles a credential itself.
- A closing summary dialog naming what was installed, what was skipped, and
  the next command to run.
- The decision logic (what to show, what each answer maps to) is factored
  separately from the `whiptail` calls themselves, so it can be exercised in
  tests with a stubbed `whiptail` on `PATH` — the same technique already
  used for `npm`/`git`/`gh` stubs elsewhere in this test suite — without
  needing a real TTY.

## Out of scope

- No change to `npx github:JoMe92/nogging init`'s own behavior — this adds a
  guided layer in front of `scripts/bootstrap`, which already calls `init`
  as its last step.
- No credential handling of Nogging's own — every login is delegated
  entirely to that tool's own, already-trusted auth flow.
- No image/sixel rendering of the actual logo PNG in the terminal — not a
  safe assumption across SSH/tmux/terminal-emulator combinations; the ASCII
  wordmark + ANSI color approximation is the portable equivalent.
- Platforms outside `scripts/bootstrap`'s existing supported set
  (Debian/Ubuntu) remain out of scope, unchanged from before this change.
