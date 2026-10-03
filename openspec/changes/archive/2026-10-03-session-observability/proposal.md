# Session observability: watch, usage-limit detection, auto-resume

## Source

Five GitHub issues, all from the same real multi-session delivery run
(VeloKine, 2026-09-28 through 2026-09-30), triaged together because they
describe one connected problem at increasing levels of maturity:

- [#22](https://github.com/JoMe92/nogging/issues/22) — the umbrella: "detect
  state, recognize usage-limit hits, auto-resume," naming #19/#20/#21 as its
  three sub-parts.
- [#19](https://github.com/JoMe92/nogging/issues/19) — `session probe`:
  classify a session's live state.
- [#20](https://github.com/JoMe92/nogging/issues/20) — recognize the
  Codex/Claude usage-limit message and extract its exact reset time.
- [#21](https://github.com/JoMe92/nogging/issues/21) — `session
  resume-when-ready`: wait out a detected rate limit and nudge the session to
  continue.
- [#23](https://github.com/JoMe92/nogging/issues/23) — filed two days after
  #19-22, by the same reporter, after running the hand-rolled version of all
  three in production across 7 parallel Claude Lead sessions. Proposes
  `scripts/nogg session watch`, a two-layer adapter architecture (pane-
  scraping plus, where available, structured hook events), and a companion
  `session send --verify` fixing a real incident where a steering message sat
  unsubmitted in a Codex session's input box for ~50 minutes, twice.

## Why this is one change, not four

#23 is not a fourth parallel proposal — it is the same reporter's **second,
more mature draft** of #19-22's goal, written after running the first draft's
logic in production and hitting its false-positive problem (every Claude pane
permanently shows `Auto-update failed: no write permission to npm prefix`,
which a naive `error`/`failed` keyword match flags as `attention` constantly).
#23's design — ignore-list, last-15-lines-only, per-agent adapters as data,
`stalled` as a distinct state from `blocked` — is a direct fix for problems
#19's leaner design does not yet account for. Treating this as four separate
pieces of work would mean building #19's classifier first and then rebuilding
most of it for #23's fixes. This change builds to #23's design from the
start and closes #19, #20, #21, and #22 as a consequence.

## Research performed

- Re-read all five issue bodies in full (not just titles) — #23 in
  particular documents concrete, production-observed pane text for both
  Claude and Codex, which this change's adapter patterns are taken from
  directly rather than re-guessed.
- Checked the installed `codex-cli 0.158.0` (`codex --help`) for the two
  structured primitives #23 flagged as unverified: `codex queue --thread
  <THREAD> --message <TEXT>` ("Queue a message for an existing session") and
  `codex agents` ("Browse all agent sessions on the shared local app-server
  daemon") both exist on this version. Whether `queue` resolves against a
  session `scripts/nogg` launched inside a dedicated tmux socket is **not**
  verified here — no live Codex session was available during planning — and
  is carried forward as an explicit implementation-time verification task
  rather than assumed.
- Confirmed Claude Code's `Stop` and `Notification` hooks exist and fire at
  the points #23's Layer-2 sketch assumes (turn end; permission/idle
  notifications) — this project already generates a per-session settings
  file at launch time (`<name>.settings.json`), which is the natural place
  to wire them.
- Checked this repository's own capability list: no existing capability
  covers cross-agent session state observation. `claude-sessions` is
  explicitly Claude-only (tmux/metadata/log supervision); this change adds a
  new `session-observability` capability rather than overloading that one,
  following the precedent `agent-neutral-launch` set for other per-agent
  behavior described under one roof.

## What Changes

- **`scripts/nogg session watch [--all-running | <name>...] [--interval 30]
  [--stall-after 15m] [--format lines|jsonl]`** — polls each named session's
  tmux pane, classifies it via a per-agent adapter (patterns as data, not
  free-text keyword matching) into `working` / `waiting_background` /
  `idle` / `needs_input` / `limit` / `stalled` / `ended`, and emits one event
  per state transition (never a firehose). Adapters ship for `claude` and
  `codex`; `pi` is explicitly out of scope (see below).
- **Usage-limit recognition** is one of the `claude` and `codex` adapters'
  own pattern sets, not a separate mechanism: a session in the `limit` state
  carries a parsed, absolute reset timestamp in the event
  (`limit until=<ISO8601>`), resolved against the host's local date/time.
- **`scripts/nogg session resume-when-ready <name> [--message "..."]`** —
  uses `watch` to wait out a `limit` state, safely dismisses a residual
  "switch model?" prompt without acting on it (switching models does not
  bypass a genuine account-wide limit — documented, not just coded around),
  and sends a resume instruction via the agent-appropriate key-injection
  sequence.
- **`scripts/nogg session send <name> "<message>" [--verify]`** — the
  companion fix for the lost-message incident: sends a message, and with
  `--verify`, confirms it was actually submitted (not left sitting in an
  input box) before returning, retrying the submit step once per the known
  per-agent quirk (Claude Code's second-bare-`Enter` requirement after a
  multi-line paste; Codex verified empirically during implementation).
- **Claude Layer-2 hooks**: `session launch` wires `Stop` and `Notification`
  hooks into the per-session settings file, each invoking a new
  `scripts/nogg session emit <event>` that appends a structured line to
  `<name>.events.jsonl`. `watch` prefers this file over pane-scraping for a
  Claude session once it exists, removing the `Auto-update failed` class of
  false positive at the source rather than only filtering it out.

## Out of scope (explicit follow-ups, not silently dropped)

- **Pi adapter.** Pi is not installed on this host and its pane text for
  working/idle/prompt states has never been observed; #23 itself left this
  unspecified for the same reason. A follow-up needs a live
  `session launch --agent pi` run to capture real patterns before an adapter
  can be written responsibly.
- **Codex Layer 2** (`codex queue` / `codex agents` as a structured
  alternative to pane-scraping for Codex). Flagged above as unverified
  against a `scripts/nogg`-launched session; carried as an implementation
  task (TASK-SOB-006) with Layer-1 pane-scraping as the Codex path's
  fallback either way, not as a blocking dependency for the rest of this
  change.
- **`pr_ready` event** (watch reporting when a session's branch has an open,
  checked pull request). Independently useful, independently small, and not
  needed for the usage-limit / lost-message problems this change exists to
  fix — left as a natural next issue rather than widening this one further.
- **Push notifications / alerting to a human.** Per #22's own stated
  non-goal, this stays a host concern (e.g. Claude Code's own `Monitor` /
  `PushNotification` tooling), not something Nogging emits itself.
