# Reading Model Usage and Rate Limits

How the Nogging Orchestrator and human operators inspect 5-hour and weekly usage
limits across OpenAI Codex, Anthropic Claude Code, and Google Antigravity (`agy`).

Autonomous execution consumes rate limits and token quotas. Before launching
resource-intensive implementation batches, planning sessions, or test suites,
the Orchestrator checks available headroom to avoid mid-task exhaustion and to
schedule resumption once a rate limit resets.

All commands documented here run locally on the delivery host and inspect local
session logs or authenticated CLI tools. **No credentials, API tokens, or secrets
are accepted on the command line or printed in the output.**

## Summary and worked example

| Tool / Provider | 5-Hour Window (Primary / Session) | Weekly Window (Secondary) | Inspection Source |
| --- | --- | --- | --- |
| **OpenAI Codex** (`plan_type: plus`) | `primary`: `window_minutes: 300` (5h), `used_percent: 51.0%`, reset `1791676037` | `secondary`: `window_minutes: 10080` (7d), `used_percent: 67.0%`, reset `1791956949` | Latest `payload.rate_limits` in `~/.codex/sessions/**/rollout-*.jsonl` (`errors="replace"`) |
| **Claude Code** (Subscription) | `Current session`: `24% used`, resets `Oct 10, 11:09pm (Europe/Berlin)` | `Current week (all models)`: `7% used`, resets `Oct 17, 12:59pm (Europe/Berlin)` | `claude -p '/usage'` |
| **Antigravity** (`Gemini Models`) | `window: "5h"`: `remaining_fraction: 0.9607` (~4% used), reset `2026-10-10T21:39:02Z` | `window: "weekly"`: `remaining_fraction: 0.9458` (~5% used), reset `2026-10-13T20:14:27Z` | `agy --print /usage --output-format json` (`command.data.groups[0]`) |
| **Antigravity** (`Claude and GPT models`) | `window: "5h"`: `remaining_fraction: 1.0` (0% used), reset `2026-10-11T00:51:39Z` | `window: "weekly"`: `remaining_fraction: 1.0` (0% used), reset `2026-10-17T19:51:39Z` | `agy --print /usage --output-format json` (`command.data.groups[1]`) |

---

## OpenAI Codex

Codex records live rate-limit events directly in session rollouts under
`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Each turn that processes tokens
appends an `event_msg` with `payload.type == "token_count"` containing a
`payload.rate_limits` object.

### Rate-limit structure

- `primary`: The 5-hour rolling window (`window_minutes: 300`), reporting
  `used_percent` (float) and `resets_at` (Unix epoch seconds).
- `secondary`: The 7-day rolling window (`window_minutes: 10080`), reporting
  `used_percent` (float) and `resets_at` (Unix epoch seconds).
- `plan_type`: Subscription tier (e.g. `"plus"`).
- `credits`: Credit balance state (`has_credits`, `unlimited`, `balance`).

### Verified command

Rollout files may contain arbitrary binary fragments or non-UTF-8 surrogates
from executed tools and model reasoning streams. Always open files with
`errors="replace"` to prevent `UnicodeDecodeError`.

```python
python3 - <<'PY'
import glob, json, os

files = sorted(glob.glob(os.path.expanduser("~/.codex/sessions/**/rollout-*.jsonl"), recursive=True))
if not files:
    raise SystemExit("No Codex session rollout files found.")

latest_file = files[-1]
latest_limits = None

with open(latest_file, "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        if '"rate_limits"' in line:
            try:
                data = json.loads(line)
                if "payload" in data and "rate_limits" in data["payload"]:
                    latest_limits = data["payload"]["rate_limits"]
            except Exception:
                pass

if not latest_limits:
    raise SystemExit(f"No rate_limits payload in {latest_file}")

print(f"File: {latest_file}")
print(json.dumps(latest_limits, indent=2))
PY
```

### Real output shape

```json
{
  "limit_id": "codex",
  "limit_name": null,
  "primary": {
    "used_percent": 51.0,
    "window_minutes": 300,
    "resets_at": 1791676037
  },
  "secondary": {
    "used_percent": 67.0,
    "window_minutes": 10080,
    "resets_at": 1791956949
  },
  "credits": {
    "has_credits": false,
    "unlimited": false,
    "balance": "0"
  },
  "individual_limit": null,
  "spend_control_reached": null,
  "plan_type": "plus",
  "rate_limit_reached_type": null
}
```

---

## Anthropic Claude Code

Claude Code provides a non-interactive print mode (`-p`) that executes the
built-in `/usage` slash command.

### Verified command

```bash
claude -p '/usage'
```

### Output fields

- **Current session**: The 5-hour rolling window usage percentage and reset
  timestamp formatted in local time with timezone designation.
- **Current week (all models)**: The weekly rolling window usage percentage
  and reset timestamp across all Claude models.
- **Current week (<model>)**: Model-specific breakdown if applicable (e.g. Fable).
- **Contributing usage**: Local host activity metrics (requests, session count,
  context distribution, subagent usage).

### Real output shape

```text
You are currently using your subscription to power your Claude Code usage

Current session: 24% used · resets Oct 10, 11:09pm (Europe/Berlin)
Current week (all models): 7% used · resets Oct 17, 12:59pm (Europe/Berlin)
Current week (Fable): 7% used · resets Oct 17, 12:59pm (Europe/Berlin)

What's contributing to your limits usage?
Approximate, based on local sessions on this machine — does not include other devices or claude.ai. Behaviors are independent characteristics, not a breakdown.

Last 24h · 670 requests · 13 sessions
  74% of your usage was at >150k context
  73% of your usage came from subagent-heavy sessions
  Top skills: /loop 5%

Last 7d · 9751 requests · 56 sessions
  87% of your usage was at >150k context
  36% of your usage came from subagent-heavy sessions
  29% of your usage came from sessions active for 8+ hours
  26% of your usage was while 4+ sessions ran in parallel
  Top skills: /loop 4%
  Top subagents: general-purpose 3%
```

---

## Google Antigravity (`agy`)

Antigravity CLI exposes the `/usage` slash command in headless JSON mode via
`--print /usage --output-format json`.

### Verified command

```bash
agy --print /usage --output-format json
```

### JSON structure and fields

The output includes a `command.data` object defining two model groups:

1. `Gemini Models` (e.g. Gemini Flash, Gemini Pro)
2. `Claude and GPT models` (e.g. Claude Opus, Claude Sonnet, GPT-OSS)

Within each group, `buckets[]` provides the rate limits:

- `id`: Bucket identifier (e.g. `gemini-5h`, `gemini-weekly`, `3p-5h`, `3p-weekly`).
- `window`: Window identifier (`"5h"` or `"weekly"`).
- `remaining_fraction`: Float between `0.0` (exhausted) and `1.0` (full capacity).
  Subtract from 1 to obtain used percentage (e.g. `1 - 0.960678 = ~3.93%` used).
- `reset_time`: ISO-8601 UTC timestamp string (e.g. `"2026-10-10T21:39:02Z"`).

### Real output shape

```json
{
  "conversation_id": "",
  "status": "SUCCESS",
  "response": "Gemini Models\tWeekly Limit Remaining\t95%\t2026-10-13T20:14:27Z\nGemini Models\tFive Hour Limit Remaining\t96%\t2026-10-10T21:39:02Z\nClaude and GPT models\tWeekly Limit Remaining\t100%\t2026-10-17T19:51:39Z\nClaude and GPT models\tFive Hour Limit Remaining\t100%\t2026-10-11T00:51:39Z\n",
  "duration_seconds": 0,
  "num_turns": 0,
  "usage": {
    "input_tokens": 0,
    "output_tokens": 0,
    "thinking_tokens": 0,
    "cache_read_tokens": 0,
    "total_tokens": 0
  },
  "command": {
    "name": "usage",
    "data": {
      "description": "Within each group, models share a weekly limit and a 5-hour limit. Quota is consumed proportionally to the cost of the tokens. Thus, limits will last longer with shorter tasks or using more cost-effective models. The 5-hour limit smooths out aggregate demand to fairly distribute global capacity across all users, while your weekly limit is tied directly to your individual tier.",
      "groups": [
        {
          "name": "Gemini Models",
          "description": "Models within this group: Gemini Flash, Gemini Pro",
          "buckets": [
            {
              "id": "gemini-weekly",
              "name": "Weekly Limit Remaining",
              "description": "You have used some of your weekly limit, it will fully refresh in 3 days.",
              "window": "weekly",
              "remaining_fraction": 0.9457745552062988,
              "reset_time": "2026-10-13T20:14:27Z"
            },
            {
              "id": "gemini-5h",
              "name": "Five Hour Limit Remaining",
              "description": "You have used some of your 5-hour limit, it will fully refresh in 1 hour, 47 minutes.",
              "window": "5h",
              "remaining_fraction": 0.9606783986091614,
              "reset_time": "2026-10-10T21:39:02Z"
            }
          ]
        },
        {
          "name": "Claude and GPT models",
          "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
          "buckets": [
            {
              "id": "3p-weekly",
              "name": "Weekly Limit Remaining",
              "window": "weekly",
              "remaining_fraction": 1,
              "reset_time": "2026-10-17T19:51:39Z"
            },
            {
              "id": "3p-5h",
              "name": "Five Hour Limit Remaining",
              "window": "5h",
              "remaining_fraction": 1,
              "reset_time": "2026-10-11T00:51:39Z"
            }
          ]
        }
      ]
    }
  }
}
```

---

## Local-time conversion

The tools express reset points in different formats. Convert them to the local
delivery host timezone (`Europe/Berlin` in these examples):

### 1. Codex Unix timestamps (epoch seconds)

Codex outputs integer seconds since epoch (e.g. `1791676037`).

- **Bash**:
  ```bash
  date -d @1791676037 "+%Y-%m-%d %H:%M:%S %Z"
  # => 2026-10-10 23:07:17 CEST
  ```
- **Python**:
  ```python
  from datetime import datetime, timezone
  dt = datetime.fromtimestamp(1791676037, tz=timezone.utc).astimezone()
  print(dt.strftime("%Y-%m-%d %H:%M:%S %Z"))
  # => 2026-10-10 23:07:17 CEST
  ```

### 2. Claude Code formatted strings

Claude Code outputs human-readable strings already converted to the local
timezone, including the timezone identifier (e.g. `Oct 10, 11:09pm (Europe/Berlin)`).
No conversion is necessary.

### 3. Antigravity ISO-8601 UTC timestamps

Antigravity outputs standard ISO-8601 UTC strings with a `Z` suffix
(e.g. `2026-10-10T21:39:02Z`).

- **Bash**:
  ```bash
  date -d "2026-10-10T21:39:02Z" "+%Y-%m-%d %H:%M:%S %Z"
  # => 2026-10-10 23:39:02 CEST
  ```
- **Python**:
  ```python
  from datetime import datetime
  dt = datetime.fromisoformat("2026-10-10T21:39:02Z").astimezone()
  print(dt.strftime("%Y-%m-%d %H:%M:%S %Z"))
  # => 2026-10-10 23:39:02 CEST
  ```

---

## Caveats and operational constraints

1. **Estimates, not guarantees**:
   Usage percentages and remaining fractions reported by model providers are
   approximations. Factors such as prompt caching rates, reasoning/thinking
   tokens, and dynamic window shifting mean that capacity should never be
   budgeted down to the final 1%. Keep a safe operational margin before running
   large multi-turn sessions.

2. **Same-host statistics vs account-wide quota**:
   Session activity counters (e.g., Claude's "Last 24h · 13 sessions") reflect
   local activity on this delivery host. However, the quota limits themselves
   are account-wide. If an account is shared with interactive web sessions or
   another runner, remote usage consumes the same pool.

3. **`agy` exit code 0 / status `SUCCESS` is not proof of execution**:
   A successful process exit (code 0) and `"status": "SUCCESS"` from `agy`
   merely indicate that the CLI completed its invocation without an unhandled
   exception. They do **not** prove that quota was sufficient for downstream
   actions, that tools were permitted by pre-tool hooks, or that commands
   executed without timeout. Tool automations must inspect the inner data
   payloads and verify filesystem effects directly.

4. **Credential safety**:
   None of these commands log or print API keys, auth headers, cookies, or
   credentials. All inspection commands are safe to invoke inside supervised logs
   and audit trails.
