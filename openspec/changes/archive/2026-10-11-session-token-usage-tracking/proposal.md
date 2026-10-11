## Why

Operators cannot currently compare attributable token consumption and runtime across supervised Claude, Codex and Antigravity sessions. Persisting usage with the actual model, task and task complexity makes model-selection decisions measurable and preserves history when session records are cleaned up or work moves to another device.

## What Changes

- Collect source-reported input, output, cache read/write and thinking counts without double-counting repeated records or cumulative summaries.
- Preserve session runtime, provider, actual model, requested selection, task identity and historical complexity (`routine`, `standard`, `complex`, or `unknown`). Defer Pi.
- Store allowlisted facts in a separate Nogging-owned Dolt database with stable identities, recovery and explicit opt-in multi-device merge/sync.
- Add `nogg token-usage` collection, reporting, session inspection, export and sync commands with JSON output, hourly/daily/session grouping and arbitrary time filters.
- Integrate automatic supervised collection and terminal/recovery handling, retaining pending facts across failures and cleanup.
- Ship packed installer support, operator guidance and unsigned acceptance evidence, including nonzero supervised usage from every supported runtime and a two-device offline-write merge.

## Capabilities

### New Capabilities

- `token-accounting`: runtime adapters, normalized counters, historical attribution and durable collection.
- `token-reporting`: queryable statistics, time windows, coverage and machine-readable reports.
- `token-store-sync`: independent usage storage, multi-device identity, conflict-safe remote synchronization and recovery.

### Modified Capabilities

None. Existing quota admission and model-selection behavior remain separately specified; this change consumes their optional metadata.

## Impact

Affects supervised lifecycle integration, `scripts/nogg`, runtime helpers, `.nogging` local state, installer/package manifests and operator documentation. Reuses the required Dolt CLI but owns a sibling database and independent private remote; never changes Beads tables or uses `bd dolt` to synchronize telemetry. No hosted service or new persistent daemon is required. Usage facts are kept outside source Git and exclude prompts, tool output and credentials. No dependency on `gate-session-usage`; optional `selection_tier` metadata follows the committed model-selection contract.
