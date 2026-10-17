## Why

Source: GitHub issue [#211](https://github.com/JoMe92/nogging/issues/211).
On a host with real quota data, `nogg usage` reported **unknown** for all
three agents and the usage gate admitted launches as `unknown-admitted`, even
while the Codex weekly window sat at 98 %:

- **Codex.** `inspect_usage()` discards a Codex observation once it is older
  than `usage_gate.stale_seconds` (600 s), although the observation's
  `resets_at` is still in the future. A 15-minute-old sample showing 98 %
  weekly became `unknown (stale observation)` and admitted a launch.
- **Antigravity.** The report ran `nogg usage --agent antigravity` without
  `--model`, so nothing could be mapped. With a model the table entries
  (`gemini-3.8-flash-low|medium|high`) already resolve to the Gemini group
  (verified against the real probe shape). The defect is that the "no model"
  case is indistinguishable from an unrecognised model and nothing guards the
  model-selection table against drifting out of the mapping.
- **Claude.** Without the opt-in statusline the output says only
  `unknown (missing usage source)`; the remedy
  (`nogg usage install-statusline`) is shown nowhere an operator looks.
- **Gate default.** With every source unknown the gate admits silently enough
  that an orchestrator running seven parallel Leads exhausts quota unnoticed.

## What Changes

- Codex observations stay valid until each window's own `resets_at` instead of
  expiring at `stale_seconds`; an aged observation is marked `stale` but still
  gates. A known window over the cap therefore denies.
- Antigravity: an unset model reports `unknown model mapping (no model
  selected; pass --model <id>)`; unrecognised models keep plain
  `unknown model mapping`; a drift guard proves every Antigravity model in the
  model-selection table maps to exactly one `/usage` group.
- Unknown windows may carry a `hint`; Claude's missing statusline source
  carries `run nogg usage install-statusline`, shown by `nogg usage`, the
  launch warning and `doctor`.
- The unknown-admitted launch warning becomes a prominent `WARN` naming agent,
  reasons and hints, and `doctor` prints a NOTE that the gate currently admits
  unknown usage and how `usage_gate.on_unknown: "deny"` changes that.

**Not changed:** `usage_gate.on_unknown` stays `warn`. Making `deny` (or an
`unknown-blocked` mode) the default would block launches on any host without
quota sources and is a **Product Owner decision**; this change only makes the
risk visible. Claude and Antigravity keep `stale_seconds` expiry (their sources
refresh on every render/probe).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `session-usage`: Codex observation lifetime; Antigravity missing-model
  reason and table coverage; remediation hints for missing sources; visible
  warning and doctor note for the unknown-admitted default.

## Impact

- `scripts/nogg_usage.py`: `inspect_usage()` (Codex staleness, `hint`),
  `agy_select_group()`, `evaluate_gate()` (carry `hint`/`stale`),
  `quota_freshness_notes()`, a new unknown-policy doctor-note helper.
- `scripts/nogg`: the `unknown-admitted` warning in `usage_gate_admission()`
  and one doctor call site.
- Existing suites touched: `scripts/usage.test.sh`, `scripts/usage-gate.test.sh`,
  `scripts/antigravity-usage.test.sh`, `scripts/packed-usage-gate.test.sh`.
- Docs: `docs/using-with-antigravity.md`, `docs/operating-model.md` usage text.
  No new config key, no authority change, no dependency.
