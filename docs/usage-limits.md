# Usage limits

How Nogging observes provider usage limits with `nogg usage`, how the launch
usage gate uses those observations, and how the raw provider probes behind
them work. It is for operators and anyone running supervised sessions who
wants to avoid mid-run rate-limit exhaustion.

All commands run locally on the delivery host. Nogging never sends usage data
anywhere and never accepts or prints credentials or tokens. The two bounded
probes for Antigravity and Pi read quota from the provider; the Pi probe
resolves its key through Pi itself and keeps it in memory.

## Checking usage with `nogg usage`

```bash
./scripts/nogg usage --agent codex
./scripts/nogg usage --agent claude
./scripts/nogg usage --agent agy --model gemini-3.8-flash-medium
./scripts/nogg usage --agent pi
./scripts/nogg usage --agent codex --json
```

The command prints, per window (a 5-hour *short* window and a *weekly*
window), how much of the provider's rolling limit is used, when the window
resets, and whether a typical launch would still fit (`fits: yes/no`).
`--json` emits the same observation in normalized form. Add `--model` when
the provider maps models to separate pools (Antigravity).

Nogging reads only local artifacts, with two bounded exceptions: the
Antigravity probe and the Pi probe described below. It does not install
capture, launch sessions or read authentication files. Missing, unsupported, malformed,
future-dated or already-reset observations are reported as **unknown**, never
as zero. Claude and Antigravity observations older than 600 seconds count as
stale; a Codex observation stays valid until the window's own reset because
Codex logs a fresh sample every turn.

Which agent reports real numbers:

| Agent | Source | Default state |
| --- | --- | --- |
| Codex | rollout session logs under `$CODEX_HOME/sessions` (default `~/.codex/sessions`) | works out of the box after Codex has run at least one turn |
| Claude Code | the opt-in statusline cache (see below) | `unknown (missing usage source)` until you run `nogg usage install-statusline` |
| Pi (Z.ai) | the shared snapshot `pi-zai.json` under `$XDG_CACHE_HOME/nogging/usage/`, refreshed by one bounded probe when it is stale; see [Pi via Z.ai](#pi-via-zai) | works out of the box when `pi` is installed and a Z.ai key is configured in Pi; other Pi providers report `unknown` |
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
./scripts/nogg usage install-statusline --dry-run   # preview, writes nothing
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
- A real install first **backs up** an existing `settings.json` byte for byte
  to `settings.json.nogging-install.bak` (mode 0600, overwritten by each real
  install) and records your previous `statusLine` value, or its absence, in
  `$XDG_DATA_HOME/nogging/claude-statusline.restore.json` next to the wrapper.
  Those two files are what `uninstall-statusline` uses.
- **Nothing is sent over the network**, and the cache lives in an
  owner-only directory.
- A malformed `settings.json` or an unsupported `statusLine` configuration
  (anything other than a command-based statusline) aborts with an
  explanation instead of guessing.

### Verifying it

1. Preview it with `./scripts/nogg usage install-statusline --dry-run`: it
   prints the wrapper path, the command it would compose with and a diff of
   `settings.json`, and writes nothing (no file, no directory). Then run
   `./scripts/nogg usage install-statusline` and check the printed
   message: it names the wrapper path, and mentions composition if you had a
   previous statusline.
2. Restart a Claude Code session so the new statusline takes effect, and let
   the statusline render once.
3. Run `./scripts/nogg usage --agent claude`. Numbers appear only after that
   first statusline run; before it you still see `unknown`.
4. `./scripts/nogg doctor` reports the observation cache as missing, stale
   or fresh.

### Undoing it

```bash
./scripts/nogg usage uninstall-statusline --dry-run   # preview, writes nothing
./scripts/nogg usage uninstall-statusline
```

`uninstall-statusline` restores **only** the `statusLine` key in
`~/.claude/settings.json` from the restore record: your previous value comes
back exactly, or the key is removed if you had none. Every other setting,
including ones you changed after installing, is preserved. It then deletes the
wrapper and the restore record. Restart Claude Code sessions afterwards.

- It first copies the current settings to `settings.json.nogging-uninstall.bak`
  (mode 0600). Together with `settings.json.nogging-install.bak` from the
  install, you have a copy of the file before each change.
- If the statusline does not reference the Nogging wrapper (never installed,
  already uninstalled, or hand-edited since), it reports `not_installed`,
  exits 0 and changes nothing.
- For an install made before the restore record existed, it restores from the
  command baked into the wrapper (your composed command, or no `statusLine`).
- If neither the record nor the wrapper can tell it the previous value, or
  `settings.json` is malformed, it refuses with manual steps and changes
  nothing. Then restore the key yourself.
- Both commands take `--json`, and `--settings` / `--wrapper-path` to target
  other paths.

The usage cache at `$XDG_CACHE_HOME/nogging/usage/claude.json` is left in
place and stops counting once it is older than `usage_gate.stale_seconds`;
delete it if you want `nogg usage --agent claude` to report unknown at once.

## Pi via Z.ai

`nogg usage --agent pi` reports the Z.ai coding-plan windows, the 5-hour
*short* window and the *weekly* window, under the model group `zai-coding-plan`.
The account stays unknown. It applies when the effective Pi provider is `zai`.
Nogging takes the provider from the launch model's `zai/` prefix, else the Pi
profile's `provider`, else `defaultProvider` in Pi's personal `settings.json`.
Any other known provider reports both windows unknown with
`no usage source for Pi provider <name>`.

**Cache first.** The source is the shared snapshot `pi-zai.json`, the same file
the [`glm-usage` extension](pi-extensions.md#glm-usage) writes while Pi runs. A
snapshot no older than `usage_gate.stale_seconds` is used as it is. As for the
other providers, a window whose reset has passed, or that resets before its own
observation, is unknown.

**The probe.** When the snapshot is stale, missing or malformed, Nogging runs one
bounded probe and rewrites the snapshot (`source: "nogg-probe"`). It runs
`pi auth print-api-key --provider zai` under a 15-second timeout with the output
captured in memory, then one `GET` to the Z.ai quota endpoint under a 10-second
timeout. The key stays in memory and goes only into that request's
`Authorization` header. It is never written to disk, passed on a command line or
into another process's environment, or shown in a report, log, session record or
error message. The endpoint is a constant with no override, and a redirect is
never followed. A failed probe never falls back to stale data. It reports both
windows unknown with one reason:

| Reason | Hint |
| --- | --- |
| `pi not installed` | `install pi` |
| `no Z.ai API key configured in Pi` | `configure the ZAI Coding Plan key in Pi (/login)` |
| `Z.ai rejected the key (HTTP <status>)` | |
| `quota probe failed (<timeout\|network>)` | |
| `unsupported quota response` | |

A snapshot that is stale while the probe is off carries the hint `run nogg usage
--agent pi`. Hints appear in `nogg usage`, in the warning of a launch admitted
with unknown usage, and in `doctor`; they never change a decision.

**`PI_NOGG_USAGE_PROBE`.** Set `PI_NOGG_USAGE_PROBE=0` (also `false`, `no` or
`off`) to make Pi observation cache-only, as `AGY_NOGG_USAGE_PROBE=0` does for
Antigravity. The repository test runner sets it, so no test touches your real
`pi`.

`doctor` never probes and makes no network call. When `pi` is on `PATH`, its
quota-freshness NOTE covers the Pi snapshot like the Antigravity one.

**Gate and routing.** Known Pi windows go through the launch gate unchanged,
with the cap, estimate, reservations and exit 75 on denial. Pi used to be
always unknown, so a routing entry's `on_unknown` for `pi` was the whole
decision; now it applies only when the quota is unknown, for example with no
key, a rejected key or another provider. The probe runs during launch admission, on the
host side before any side effect, and adds at most the two timeouts. Unknown is
never treated as zero, and no routing default changes: unknown Pi usage warns
unless you set `on_unknown` to `deny`. The endpoint is undocumented; see
[the endpoint risk](pi-extensions.md#the-undocumented-endpoint).

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
4. **Pi quota is account-wide.** Z.ai counts the account, not this host, so a
   fresh snapshot can understate use made elsewhere in that interval. A plan
   without a weekly limit leaves that window unknown.
5. **Model mapping.** Antigravity maps a model to its pool through the
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
