# Usage limits

How Nogging observes provider usage limits with `nogg usage`, how the launch
usage gate uses those observations, and how the raw provider probes behind
them work. It is for operators and anyone running supervised sessions who
wants to avoid mid-run rate-limit exhaustion.

All commands run locally on the delivery host. Nogging never sends usage data
over the network and never accepts or prints credentials or tokens.

## Checking usage with `nogg usage`

```bash
./scripts/nogg usage --agent codex
./scripts/nogg usage --agent claude
./scripts/nogg usage --agent agy --model gemini-3.8-flash-medium
./scripts/nogg usage --agent codex --json
```

The command prints, per window (a 5-hour *short* window and a *weekly*
window), how much of the provider's rolling limit is used, when the window
resets, and whether a typical launch would still fit (`fits: yes/no`).
`--json` emits the same observation in normalized form. Add `--model` when
the provider maps models to separate pools (Antigravity).

Nogging reads only local artifacts; it does not install capture, launch
sessions or touch authentication files. Missing, unsupported, malformed,
future-dated or already-reset observations are reported as **unknown**, never
as zero. Claude and Antigravity observations older than 600 seconds count as
stale; a Codex observation stays valid until the window's own reset because
Codex logs a fresh sample every turn.

Which agent reports real numbers:

| Agent | Source | Default state |
| --- | --- | --- |
| Codex | rollout session logs under `$CODEX_HOME/sessions` (default `~/.codex/sessions`) | works out of the box after Codex has run at least one turn |
| Claude Code | the opt-in statusline cache (see below) | `unknown (missing usage source)` until you run `nogg usage install-statusline` |
| Antigravity | a bounded `agy --print /usage` probe, cached under `$XDG_CACHE_HOME/nogging/usage/` | works out of the box when `agy` is installed; models outside a recognized group report `unknown model mapping` |

## Claude usage is unknown by default

Nogging never spawns `claude` to ask it for usage: that would launch a
session behind your back and consume quota. Instead, Claude Code itself can
call a *statusline* command with a JSON snapshot of your limits on every
render. Nogging can install a tiny capture wrapper as that statusline; it
records the limits to a local cache that `nogg usage` and the launch gate
then read. This is opt-in.

### What `nogg usage install-statusline` changes

```bash
./scripts/nogg usage install-statusline
```

The command changes exactly two things:

- **A wrapper script** at `$XDG_DATA_HOME/nogging/claude-statusline`
  (default `~/.local/share/nogging/claude-statusline`). When Claude Code
  feeds it the statusline JSON, it extracts the `rate_limits` object and
  writes `$XDG_CACHE_HOME/nogging/usage/claude.json` (default
  `~/.cache/nogging/usage/claude.json`) — schema version 1, an `observed_at`
  timestamp and the `rate_limits` object, nothing else.
- **The `statusLine` key** in `~/.claude/settings.json`, pointed at the
  wrapper. Other settings are untouched.

Composition and safety properties:

- If you already have a statusline, it is **composed, not replaced**: the
  wrapper captures the usage data and then invokes your previous statusline
  command with the same input, so your statusline keeps working.
- Running it twice is a **no-op** (idempotent).
- **Nothing is sent over the network**, and the cache lives in an
  owner-only directory.
- A malformed `settings.json` or an unsupported `statusLine` configuration
  (anything other than a command-based statusline) aborts with an
  explanation instead of guessing.

### Verifying it

1. Run `./scripts/nogg usage install-statusline` and check the printed
   message: it names the wrapper path, and mentions composition if you had a
   previous statusline.
2. Restart a Claude Code session so the new statusline takes effect, and let
   the statusline render once.
3. Run `./scripts/nogg usage --agent claude`. Numbers appear only after that
   first statusline run; before it you still see `unknown`.
4. `./scripts/nogg doctor` reports the observation cache as missing, stale
   or fresh.

### Undoing it

There is no uninstall command; revert manually:

1. Restore the previous value of `statusLine` in `~/.claude/settings.json`
   (your previous statusline command, if you had one — the install message
   printed it — or remove the key entirely). Restart Claude Code sessions
   afterwards.
2. Optionally delete the wrapper at
   `$XDG_DATA_HOME/nogging/claude-statusline` and the cache at
   `$XDG_CACHE_HOME/nogging/usage/claude.json`.

With the cache gone, `nogg usage --agent claude` reports unknown again.

## Launch usage gate

`./scripts/nogg session launch` admits an execution session (lead or
specialist) only when every known usage window of the launching agent still
fits: `used + reserved + estimate <= cap` per window. A refusal exits 75 and
names each limiting window with its reset time; planning and orchestrator
launches are not gated by default. Headroom reservations are tracked in a
host-local ledger under `$XDG_CACHE_HOME/nogging/usage/reservations`. A
launch admitted with unknown usage still reserves its estimate against later
fresh observations; the gate reduces risk but cannot guarantee a task fits.

Configure it with the optional `usage_gate` object in `.nogging/config.json`;
the keys and defaults are in
[configuration](configuration.md#usage_gate) and the full semantics in
[running work in sessions](running-work-in-sessions.md#launch-usage-gate).

## Caveats

1. **Estimates, not guarantees.** Usage percentages are provider estimates.
   Keep an operational safety buffer.
2. **Same-host observation.** Nogging sees only this host's local artifacts,
   while quotas are enforced account-wide across all active clients.
3. **Unknown is not zero.** A missing, stale or failed observation is
   unknown usage, warned or denied per `usage_gate.on_unknown`.
4. **Model mapping.** Antigravity maps a model to its pool through the
   group descriptions in the probe result; an unset model, an unknown model
   family or an ambiguous match is `unknown model mapping`. Other groups'
   headroom never admits a launch.

## Appendix: raw provider probes

The normalized observations above come from these provider-specific
artifacts. You normally never need them; they are here for debugging.

### OpenAI Codex

Codex logs session events to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
Each token-processing turn appends an `event_msg` whose
`payload.rate_limits` carries:

- `primary`: 5-hour rolling window (`window_minutes: 300`), with
  `used_percent` (float) and epoch-seconds `resets_at`.
- `secondary`: 7-day rolling window (`window_minutes: 10080`), same fields.

Nogging selects the newest such event of the current day. Output shape:

```json
{
  "limit_id": "codex",
  "primary": {"used_percent": 69.0, "window_minutes": 300, "resets_at": 1791676036},
  "secondary": {"used_percent": 70.0, "window_minutes": 10080, "resets_at": 1791956949},
  "plan_type": "plus"
}
```

### Anthropic Claude Code

Claude Code prints usage interactively with `claude -p '/usage'`, but Nogging
does not call it (see [Claude usage is unknown by default](#claude-usage-is-unknown-by-default)).
The wrapper cache stores the statusline `rate_limits` object; its
`five_hour` and `seven_day` windows carry `used_percentage` and epoch
`resets_at`. The schema was verified with Claude Code 2.1.296; other schemas
report unknown.

### Google Antigravity (`agy`)

```bash
agy --print /usage --output-format json
```

The result contains `groups[].buckets[]`: groups named `Gemini Models` and
`Claude and GPT models`, each with a description listing its model families
(the model-to-group mapping is read from it), and buckets with `window`
(`"5h"` / `"weekly"`), `remaining_fraction` (`0.0`–`1.0`) and ISO-8601 UTC
`reset_time`. Nogging runs this probe from a private neutral directory under
`$XDG_CACHE_HOME/nogging/usage/` with `AGY_CLI_DISABLE_AUTO_UPDATE=true`,
caches the sanitized buckets there (`antigravity.json`, owner-only) and
reuses them for `usage_gate.stale_seconds`; set `AGY_NOGG_USAGE_PROBE=0` to
make observation cache-only (the repository test runner does).

A result is accepted only when it has `status: SUCCESS`, no
`denied_actions`, no error and a `usage` command object with groups; exit
status zero alone never counts. Reservations are scoped per group, so a
running Gemini session does not consume a Claude/GPT launch's headroom. The
weekly and 5h buckets map to the gate's `weekly` and `short` windows and are
evaluated separately; a denial retries after the latest reset among the
buckets that do not fit. `session resume-when-ready` and the `limit` watch
event take the reset from every exhausted bucket of the session's group.
Pane states: the `antigravity` adapter classifies `idle`, `working`,
`needs_input` and `limit`; the exhausted-credit/limit wording is imported
runtime text that has not been observed live.
