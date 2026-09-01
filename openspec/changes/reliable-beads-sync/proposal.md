# Make Beads-to-OpenSpec reconciliation reliable

## Why

The concept conversation of 2026-08-31 (`docs/source/konversation-export.md`,
sections 3 and 11) split the sync engine into a mechanical part that needs no
judgement: close a Bead, mirror its state into OpenSpec. Closed Bead SPEC-1cu
recorded a concrete defect in that mechanical part during its verification work:

- `scripts/specforge` reads Beads with `bd list --json`, which omits closed
  issues. The sync pass then filters for `status == "closed"`, but a closed
  mapped Bead is never in the list, so its task checkbox and its
  `execution-log.md` entry are never written. The mechanical guarantee "close a
  Bead, see it reflected in OpenSpec" does not currently hold.
- The execution-log entry that sync does write is a single line naming the Bead
  and task. Section 11 asked the daemon to also carry the Bead note and the
  result commit SHA into the log, since the execution agent can never write the
  spec itself. That enrichment was never implemented.
- `pending_discoveries()` reads discoveries with `bd list --label discovery`,
  which also omits closed issues. A discovery that is closed before a planning
  session reviews it — exactly what happened to SPEC-1cu — is silently dropped
  from `./scripts/specforge discoveries`.
- A failed sync is written to `.specforge/state/last-error.json` as a flat
  `{at, error}` blob. Section 3 asked for transient-versus-permanent
  classification with bounded retry and backoff. There is no classification and
  no retry metadata, so an operator cannot tell a lock collision from an
  audit failure, or know whether a retry is expected.

## What changes

- **Closed Bead enumeration:** the sync pass enumerates every mapped Bead whose
  status is `closed`, in addition to the open and in-progress mapped Beads it
  already reads, and mirrors each closed Bead idempotently to its task checkbox
  and the change execution log. `materialize()` uses the same closed-inclusive
  read for its "already mapped" check, so re-running it for a partly-done change
  no longer duplicates the Beads of finished tasks (discovery SPEC-dvu).
- **Enriched execution-log entries:** each mirrored entry records the Bead ID,
  the closure timestamp, the Bead's human-readable note, and any implementation
  commit references that can be determined; entries stay idempotent across
  re-runs via a stable per-Bead event key.
- **Closed-discovery review:** discovery review enumerates Beads carrying the
  `discovery` label regardless of status, and tracks which discoveries a
  planning session has acknowledged so reviewed ones stop resurfacing while
  unreviewed closed ones persist.
- **Classified, bounded failure records:** a failed sync persists a structured
  failure record with a transient/permanent classification and bounded retry
  metadata (attempt count, maximum attempts, next eligible retry time), appends
  the failure to a JSONL failure log, and is cleared by the next successful
  sync. Permanent failures are not retried automatically.

## Impact

- Affected specs: `beads-sync` (new capability).
- Affected code (implementation deferred to execution): `scripts/specforge`
  (Bead enumeration, execution-log rendering, discovery read path, failure
  persistence), `scripts/specforge.test.sh` (closed fixtures), `docs/architecture.md`,
  `docs/failure-recovery.md`.
- No Beads are materialized by this planning change. No implementation files are
  edited by this planning change.
- Behavioural change for operators: `last-error.json` is replaced by a
  structured failure record; existing tooling that reads the old shape must be
  updated alongside the implementation.
