# Design — interactive bootstrap wizard

## Decision 1 — interactive is the TTY default, never a breaking change

`scripts/bootstrap` detects interactivity with `[ -t 0 ] && [ -t 1 ]`
(stdin and stdout both a terminal). When true *and* `whiptail` is available
(or gets installed — Decision 2), the wizard runs. In every other case —
CI, `curl | bash` with stdin already consumed by the pipe (stdin is **not**
a TTY in that exact invocation shape, so piped one-liners automatically stay
non-interactive), an explicit `--non-interactive` flag, or no `whiptail` —
`scripts/bootstrap` behaves exactly as it does today. This means the
documented one-liner
(`curl -fsSL .../bootstrap | bash`) is unaffected by default; a user who
wants the wizard downloads the script first
(`curl -fsSL .../bootstrap -o bootstrap && bash bootstrap`) so stdin is a
real terminal. Both paths are documented, not just the new one.

## Decision 2 — whiptail is ensured, not assumed, with a clean fallback

Before entering interactive mode, `scripts/bootstrap` checks for `whiptail`
and installs it via `apt-get install -y whiptail` if missing — the same
"check first, install only what's missing" pattern already used for
`git`/`tmux`/`gh`. If the install fails (no `apt`, no network, no `sudo`),
`scripts/bootstrap` prints a NOTE and falls back to the existing
non-interactive flow rather than failing the whole install over a cosmetic
layer — the wizard is a better experience, never a new hard requirement.

## Decision 3 — the wizard is a thin shell over existing flags, not new logic

Every dialog answer maps onto a flag `scripts/bootstrap`/`init` already
accepts (`--with-pi`, `--repo`, `--no-systemd`, `--no-hooks`, `--no-beads`).
The wizard's job is presentation and confirmation, not a second
implementation of what gets installed — after the last dialog, it builds the
exact same argument list a direct non-interactive invocation would have used
and runs the existing code path unchanged. This keeps the interactive and
non-interactive paths provably equivalent (same tested install logic) and
means a future flag automatically gets a wizard screen only when someone
deliberately adds one — it can never silently diverge from what the flags
already do.

## Decision 4 — authentication is fully delegated, never handled by Nogging

Nogging's own hard rule ("never echo a credential or token value") extends
here: the wizard only ever *detects* and *offers*, never touches a token.

| Tool | Status check | Login hand-off |
| --- | --- | --- |
| GitHub | `gh auth status` (exit code) | `gh auth login` |
| Codex | `codex login status` (exit code + text) | `codex login` |
| Claude Code | `~/.claude/.credentials.json` exists | run `claude` once (triggers its own first-run OAuth) |

Each check runs before its dialog; an already-authenticated tool is skipped
silently (no dialog shown for it at all), so a user who already has
everything configured sees zero auth prompts. A "yes, log in" answer hands
the terminal directly to that tool's own command — `scripts/bootstrap`
waits for it to exit, re-checks status, and reports success/failure in the
summary; it does not parse or store anything the tool produces.

## Decision 5 — testable decision logic, untestable widgets

`whiptail`'s actual screens cannot be meaningfully unit-tested without a
real TTY. The fix is the same one already used for `npm` elsewhere in this
suite: factor every *decision* (which dialogs to show, what each answer
should set) into plain shell functions that take a already-known answer and
return/export the resulting flag — then test those functions directly, and
separately stub a `whiptail` binary on `PATH` that returns canned exit
codes/output to prove the calling order and argument-building wiring, not
the rendered box itself. Visual/manual verification (per `docs/releasing.md`'s
existing evidence pattern) stays a documented, separate step for the actual
rendered experience.

## Non-goals

- No change to which versions get installed, or to the pinned-tag/
  pin-consistency mechanics `bootstrap-installer` already shipped.
- No sixel/image rendering of the logo (`proposal.md`).
- No platform expansion beyond Debian/Ubuntu.
