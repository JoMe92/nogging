# Reading Model Usage and Rate Limits

How the Nogging Orchestrator and human operators inspect 5-hour and weekly usage
limits across OpenAI Codex, Anthropic Claude Code, and Google Antigravity (`agy`).

Autonomous runs consume rate limits. Before launching heavy implementation
batches or planning sessions, check available headroom to avoid mid-run
exhaustion.

All commands run locally on the delivery host. **No credentials or tokens are
accepted on the command line or printed in the output.**

## Summary and worked example

| Tool / Provider | 5-Hour Window (Primary / Session) | Weekly Window (Secondary) | Inspection Source |
| --- | --- | --- | --- |
| **OpenAI Codex** (`plan_type: plus`) | `primary`: `window_minutes: 300` (5h), `used_percent: 69.0%`, reset `1791676036` | `secondary`: `window_minutes: 10080` (7d), `used_percent: 70.0%`, reset `1791956949` | Daily `payload.rate_limits` in `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| **Claude Code** (Subscription) | `Current session`: `24% used`, resets `Oct 10, 11:09pm (Europe/Berlin)` | `Current week (all models)`: `7% used`, resets `Oct 17, 12:59pm (Europe/Berlin)` | `claude -p '/usage'` |
| **Antigravity** (`Gemini Models`) | `window: "5h"`: `remaining_fraction: 0.9607` (~4% used), reset `2026-10-10T21:39:02Z` | `window: "weekly"`: `remaining_fraction: 0.9458` (~5% used), reset `2026-10-13T20:14:27Z` | `agy --print /usage --output-format json` |
| **Antigravity** (`Claude and GPT models`) | `window: "5h"`: `remaining_fraction: 1.0` (0% used), reset `2026-10-11T00:51:39Z` | `window: "weekly"`: `remaining_fraction: 1.0` (0% used), reset `2026-10-17T19:51:39Z` | `agy --print /usage --output-format json` |

---

## OpenAI Codex

Codex logs session events to `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Each
token-processing turn appends an `event_msg` containing `payload.rate_limits`.

### Fields
- `primary`: 5-hour rolling window (`window_minutes: 300`), `used_percent` (float), `resets_at` (epoch seconds).
- `secondary`: 7-day rolling window (`window_minutes: 10080`), `used_percent` (float), `resets_at` (epoch seconds).

### Verified command
Iterates over all rollout files of the current day, opening each with `errors="replace"` to handle arbitrary bytes, and selects the entry with the latest timestamp:

```bash
python3 - <<'PY'
import glob, json, os
from datetime import datetime

today_dir = os.path.expanduser(f"~/.codex/sessions/{datetime.now().strftime('%Y/%m/%d')}")
latest_entry, latest_ts = None, ""

for path in glob.glob(os.path.join(today_dir, "rollout-*.jsonl")):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"rate_limits"' in line:
                try:
                    obj = json.loads(line)
                    if "payload" in obj and "rate_limits" in obj["payload"]:
                        ts = obj.get("timestamp", "")
                        if ts >= latest_ts:
                            latest_ts = ts
                            latest_entry = obj["payload"]["rate_limits"]
                except Exception:
                    pass

if latest_entry:
    print(json.dumps(latest_entry, indent=2))
PY
```

### Output shape
```json
{
  "limit_id": "codex",
  "primary": {
    "used_percent": 69.0,
    "window_minutes": 300,
    "resets_at": 1791676036
  },
  "secondary": {
    "used_percent": 70.0,
    "window_minutes": 10080,
    "resets_at": 1791956949
  },
  "plan_type": "plus"
}
```

---

## Anthropic Claude Code

Claude Code prints usage stats non-interactively via print mode (`-p`).

### Verified command
```bash
claude -p '/usage'
```

### Output shape (first 4 lines)
```text
You are currently using your subscription to power your Claude Code usage

Current session: 24% used · resets Oct 10, 11:09pm (Europe/Berlin)
Current week (all models): 7% used · resets Oct 17, 12:59pm (Europe/Berlin)
```

- **Current session**: 5-hour rolling limit window, percent used, and local reset time.
- **Current week (all models)**: Weekly limit window across all models and local reset time.

---

## Google Antigravity (`agy`)

Antigravity CLI outputs structured usage limits via `--print /usage --output-format json`.

### Verified command
```bash
agy --print /usage --output-format json
```

### Output shape (`groups[].buckets[]`)
```json
[
  {
    "name": "Gemini Models",
    "buckets": [
      {
        "id": "gemini-weekly",
        "window": "weekly",
        "remaining_fraction": 0.9458,
        "reset_time": "2026-10-13T20:14:27Z"
      },
      {
        "id": "gemini-5h",
        "window": "5h",
        "remaining_fraction": 0.9607,
        "reset_time": "2026-10-10T21:39:02Z"
      }
    ]
  },
  {
    "name": "Claude and GPT models",
    "buckets": [
      {
        "id": "3p-weekly",
        "window": "weekly",
        "remaining_fraction": 1.0,
        "reset_time": "2026-10-17T19:51:39Z"
      },
      {
        "id": "3p-5h",
        "window": "5h",
        "remaining_fraction": 1.0,
        "reset_time": "2026-10-11T00:51:39Z"
      }
    ]
  }
]
```

- **Groups**: `Gemini Models` and `Claude and GPT models`.
- **Buckets**: `window` (`"5h"` / `"weekly"`), `remaining_fraction` (`0.0`..`1.0`), `reset_time` (ISO-8601 UTC).

---

## Local-time conversion

- **Codex (Unix epoch seconds)**:
  `date -d @1791676036 "+%Y-%m-%d %H:%M:%S %Z"`  
  Python: `datetime.fromtimestamp(1791676036, tz=timezone.utc).astimezone()`
- **Claude Code**: Formatted in local time already (e.g. `Oct 10, 11:09pm (Europe/Berlin)`).
- **Antigravity (ISO-8601 UTC)**:
  `date -d "2026-10-10T21:39:02Z" "+%Y-%m-%d %H:%M:%S %Z"`  
  Python: `datetime.fromisoformat("2026-10-10T21:39:02Z").astimezone()`

---

## Caveats and constraints

1. **Estimates, not guarantees**: Rate limit percentages and remaining fractions are provider estimates. Maintain an operational safety buffer.
2. **Same-host statistics**: Local session counts and rollouts reflect this delivery host, while quotas are enforced account-wide across all active clients.
3. **`agy` exit code 0 / status `SUCCESS`**: Exit code 0 and `"status": "SUCCESS"` indicate process termination without crash; they do not prove quota availability or action execution. Inspect `command.data` directly.
4. **Credential safety**: No API keys, tokens, or credentials are required or output by these commands.
