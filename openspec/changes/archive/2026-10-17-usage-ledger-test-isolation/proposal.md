## Why

Sources: [GitHub issue #163](https://github.com/JoMe92/nogging/issues/163)
and [GitHub issue #164](https://github.com/JoMe92/nogging/issues/164).
Mixed Nogging versions share one host-wide reservation ledger, but v2.2.0
crashes on develop's backend-neutral entries. Direct test invocations also
inherit real session identity and authority, causing planning/guard failures
and potentially sending fixture task ticks to the operator's live broker.

## What Changes

- Version reservation entries without splitting host-wide accounting or
  changing the top-level token map. Continue reading both unversioned formats.
- Make readers conservative about unsupported versions and malformed session
  metadata: retain valid accounting, never probe or reap opaque entries, and
  refuse safely when accounting cannot be understood.
- Make all affected test entry points remove inherited `NOGG_*` and
  `NOGGING_ROOT` before imports, fixture setup or subprocesses. Use one shared
  bootstrap rather than a fixed variable list; fixtures opt back in explicitly.
- Turn failed planning setup in `nogg.test.sh` into named failures.
- Add deterministic mixed-version, direct-invocation and broker-isolation
  regressions, and document the update requirement for older consumers.

## Capabilities

### New Capabilities

- `test-isolation`: direct planning and OpenSpec-guard tests isolate their
  fixture environment from the calling supervised session, including its broker.

### Modified Capabilities

- `session-usage`: a stable reservation accounting contract, per-entry schema
  version, tolerant reads and conservative handling of future entries.
- `session-backends`: backend liveness probing is restricted to understood
  reservation versions and shapes, while legacy reservations remain readable.

## Impact

- `scripts/nogg_usage.py`; existing usage reservation/gate/packed tests and
  new task-specific suites.
- `scripts/test`, a shared helper under `scripts/lib/`, and all test entry
  points that execute planning commands or OpenSpec guards, directly or through
  another harness. Include the helper in shipped test payloads where necessary.
- Usage and session/recovery documentation; no new dependency or service.
- Development and patched consumers interoperate. Unpatched v2.2.0 cannot be
  made tolerant by a new version field alone and still requires updating.

## Non-Goals

No implementation during planning; no release/tag, push, automatic upgrade,
ledger-path split, live ledger migration/deletion, weakened production guard,
session restart or human acceptance sign-off. Other active changes retain
ownership of session input, orchestrator restart and tmux diagnostics.
