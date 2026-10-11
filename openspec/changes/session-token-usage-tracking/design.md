## Context

Baseline is develop `93fea97`, including the approved `automatic-model-and-effort-selection` plan. The Product Owner confirmed its exact tiers (`routine`, `standard`, `complex`) and `unknown` for absent/legacy classification; Pi is deferred. See proposal.md for motivation.

Independent source inspection on 2026-10-11 found:

- Three recent Codex rollouts contain top-level `token_usage_record`, carrying response/session/thread/turn identities and incremental `usage`, alongside overlapping `event_msg/token_count` summaries. `turn_context` supplies model/effort and `session_meta` supplies provider. Never sum both streams. The observed counters include cached input, cache writes and reasoning output; observed total equals input plus output.
- Claude assistant records include message ID/model and cache-aware usage. One live file had 42 usage-bearing records but 19 distinct message IDs, with repeated identical counters. Nested iterations and cache TTL splits are breakdowns. Counting every assistant record is incorrect.
- Antigravity 1.3.3 live `--print /usage --output-format json` returned usage/duration/turn fields, all zero for the command itself. Independently inspected saved inference-result artifacts had input 14424/14427, output 32/75, thinking 31/74 and totals 14456/14502. This establishes inference-result shape, not cumulative interactive-session retrieval. Adapter work MUST verify an exact supervised conversation source with nonzero usage and real model attribution. The source may be existing export/events/result data; do not launch extra inference to measure another session. If unavailable, record a blocking discovery rather than advertise Antigravity completeness or substitute quota data.

Discovery review found existing sandbox cleanup limitations (SPEC-hjir), inherited-session test environment problems, and the requirement to keep runtime permission guarantees honest. Preserve pending evidence and isolate scratch-test environments; unrelated discoveries remain pending. Initial doctor reported no ready archive. During validation, doctor newly reported complete-session-liveness ready based on closed Beads, but its final acceptance remains on unintegrated PR #93 and canonical develop has an owner-written uncommitted task tick. Defer that archive to preserve in-flight evidence; closure alone is not integration.

## Goals / Non-Goals

**Goals:** durable local accounting despite process/network failures, historical task/model/complexity attribution, and offline independent-device writes that converge without losing facts.

**Non-Goals:** Pi adapters, pricing/billing claims, automatic complexity classification, model routing, quota admission/reservations, global quota coordination, installing services, transcript replication or human acceptance sign-off.

## Decisions

### 1. A sibling Dolt database owns usage

Use a Nogging-owned Dolt repository at canonical-main-checkout `.nogging/state/token-usage/database/`, shared by linked worktrees, with a separate remote and schema. Use supported Dolt CLI transactions, serialized by a host collector lock, without requiring a new SQL server or persistent service. Never mutate Beads' database or use `bd dolt` for telemetry. The existing required Dolt installation, SQL filtering and row-aware merge justify this choice for small batched writes. Measure actual Pi ingestion/query costs in acceptance; do not invent performance guarantees.

| Option | Assessment |
| --- | --- |
| Same Beads database/new table | Reject: third-party migrations, backup, remote and ownership would become coupled to telemetry. |
| Sibling Dolt | Select: independent lifecycle, offline SQL, primary-key-aware merge, existing tool dependency. Requires deliberate synchronization and conflict handling. |
| SQLite plus rsync/backup | Excellent local queries, but copying is not union of independent writes. Requires a separate event-exchange/import protocol. Viable alternative if Dolt overhead becomes material. |
| Litestream / LiteFS | Backup or primary/replica topology does not meet disconnected independent-device writes by itself. |
| Turso | Has newer offline/local-first sync; introduces SDK/deployment/account dependencies absent from the current architecture. Reconsider for a hosted product. |
| JSONL committed to Git | Per-device immutable files could merge, but need query indexing and an additional protocol. Shared append files conflict; source Git is an unsuitable private telemetry store. Use JSONL for portable export only. |

Research sources: [Dolt conflicts](https://www.dolthub.com/docs/concepts/dolt/git/conflicts/), [Dolt merges](https://www.dolthub.com/docs/sql-reference/version-control/merges/), [Dolt CLI](https://www.dolthub.com/docs/cli-reference/cli/), [SQLite remote copy](https://www.sqlite.org/rsync.html), [Litestream VFS](https://litestream.io/reference/vfs/), [LiteFS primary](https://fly.io/docs/litefs/primary/), [Turso offline writes](https://turso.tech/blog/introducing-offline-writes-for-turso), [new Turso sync](https://turso.tech/blog/sync-benchmark). Consult the archived multi-machine-beads-sync decision for the existing explicit trusted synchronization posture; its `bd` commands are not reusable for this database.

### 2. Versioned immutable facts and derived current views

Schema version 1 has these logical tables and indexed query dimensions:

| Table | Identity and content |
| --- | --- |
| store_meta | schema version, project UUID, identity contract version; seeded once and cloned to other devices |
| devices | generated device UUID, display hostname; no auto-increment shared identity |
| session_segments | immutable segment-start identity and runtime/supervised/parent IDs; restart creates a new segment |
| lifecycle_events | segment + stable event ID; process start/exit/heartbeat, UTC boundaries, monotonic duration evidence |
| attribution_events | stable boundary ID; task/Bead/change/planning/role, complexity and selection provenance |
| usage_events | global runtime source identity + response/message identity + revision identity; normalized/projected counters and source timestamp |

Reports derive effective latest supported revisions and interval ownership rather than maintaining cross-device aggregate counters. Local offsets, leases and retry metadata are outside the synchronized tables. Hashes use a versioned canonical allowlisted encoding; exact event replay is a no-op. A same revision identity with different contents is corruption/conflict, never an upsert. Supported later source snapshots append revisions ordered by source revision/ordinal, not importer wall clock. Deduplication identity excludes device and path so copied sources do not count twice. Identical replay must not add importer-specific timestamps or paths to canonical rows. One device owns each source stream; migration requires explicit ownership transfer, not simultaneous polling writers.

Project UUID is shared when cloning the usage store and is not derived from checkout paths. Devices generate their own UUID; hostname is presentation only. Origin runtime conversation + response identity distinguishes usage across restarts; resume segment attribution partitions new events without recharging old history. Parent/child source streams remain individually identifiable. Attribute each source event once; unproven parent-inclusive totals never add to child-exclusive events.

### 3. Counter semantics are explicit

Canonical fields: inclusive input, output, cache read, cache write, thinking, provider total, provider inference duration, source schema/version and completeness/semantics flags. Cache and thinking are diagnostic subsets, not additional totals. Claude inclusive input is uncached input + cache read + cache creation; Codex observed input already includes cache. Thinking is included in output for verified versions. Preserve the original allowlisted numeric usage fields for audit and flag inconsistency rather than silently repair provider total. Unsupported counters are NULL, observed zero is zero. Each report exposes unknown-counter counts alongside known sums.

[Claude monitoring documentation](https://code.claude.com/docs/en/monitoring-usage) confirms cache exclusion from raw input; [Codex configuration documentation](https://developers.openai.com/codex/config-advanced) documents observability counters. The exact rollout formats above are installed-version observations, not a promised stable public API. Each adapter uses sanitized fixtures and version detection; unsupported formats retain pending work and diagnostic status.

Prefer Codex per-response `token_usage_record.usage`; never also charge turn/thread totals or token_count. Older-format fallback must establish delta/reset semantics and a mutually exclusive source mode. Claude deduplicates conversation/request/message identities and handles repeated or revised streaming snapshots. Antigravity must distinguish command usage, inference-result increments and conversation totals; absent cache-write or model evidence stays unknown.

### 4. Snapshot attribution without depending on automatic routing

Snapshot task ID, Bead ID, change, planning ID, role, requested model/source, actual observed provider/model, configured/observed effort, complexity source, vocabulary version and selection-table version/hash at the applicable boundary. Consume `selection_tier` when present; allow an explicit validated `--complexity <routine|standard|complex>` at launch without selecting a model. If both it and selection_tier are supplied, disagreement refuses before launch side effects. Missing metadata maps to `unknown`, never a default tier or inference from model. Do not rewrite historical classifications from today's Bead or table.

Model-selection integration is optional: if its launch contract is not installed, explicit complexity still works and legacy records remain readable. Its tier vocabulary is already approved, so no execution dependency on MES is needed. Observe actual model per source event; requested model alone is not proof of actual model. A task handoff creates an attribution boundary through the supervisor's existing operator-directed task mechanism; uncertain ownership remains unknown. Planning/orchestrator sessions can have no Bead. Separately supervised specialists carry their own usage; in-process child source mapping requires evidence to prevent duplicate charging.

### 5. Collect through the host supervisor

Automatic collection runs at lifecycle/turn notifications when available and bounded existing supervisor refresh/recovery passes otherwise, plus final flush on exit and before cleanup. `token-usage collect` is an explicit catch-up operation, not the sole collection mechanism. Integrate deterministic host code; no agent promise to self-report is required. Restricted agents receive no new database credentials, remote access or arbitrary file authority. Use the existing host broker/lifecycle boundary, validating session identity and source roots. Never parse pane text as authoritative usage.

Durably spool allowlisted normalized facts and attribution before acknowledging collection when Dolt is unavailable. Commit imported batches and advance local source offsets only after durable success; a crash between them replays idempotently. Retry partial final lines, detect truncation/rotation, and preserve pending evidence across process death and cleanup. Cleanup refuses deletion of sole unpersisted mapping/evidence, with a remedy. Database failure is visible in doctor and does not fail the user's underlying task. Missing/malformed source yields partial/unsupported status, not complete zero. Bead-less long-lived orchestrators and resumed sessions are included.

Wall runtime is sum of observed process segments, including idle time and excluding restart downtime. Monotonic elapsed is preferred, with UTC interval boundaries retained. Live durations are provisional; an unobserved crash end yields a partial bound from last liveness evidence, not elapsed time until collection. Provider inference duration is a separate metric. Window runtime clips segment overlaps; session wall time is not repeated for every model row.

### 6. Reporting is consumption accounting

Add `nogg token-usage collect [--session ID]`, `report --from ISO --to ISO --group-by hour|day|session [--json]`, `session ID [--json]`, `export --from ISO --to ISO --format jsonl`, `sync`, and `status [--json]`. Report filters include project/device/runtime/provider/model/task/complexity/effort. Use UTC half-open ranges and UTC hour/day buckets in v1, documented explicitly; local timezone bucketing is deferred. Missing grouping filters default to daily current UTC day; session inspection is lifetime for that session. Invalid dates/ranges/filters fail with actionable errors.

Tokens belong to source response completion timestamps; coarse cumulative-only deltas expose their observation interval and coarse quality, never fabricated proportional allocation. Reports show as-of, source coverage/errors, unknown attribution/counters, pending spool and last successful sync. JSON is versioned and stable for orchestrator consumption. Tokens, inference time and wall runtime have distinct columns. Export contains normalized facts/identities/version for portable recovery, not source transcript text. No prices or quota percent conversion.

### 7. Explicit multi-device sync, local writes always work

Provide an explicit independently configured private Dolt remote; no remote is created or contacted by init/collect/report. `token-usage sync` is allowed only to trusted operator/orchestrator authority; restricted collection stays local. The existing Beads `multi_machine` flag does not silently enable usage sync. Configure the usage remote through documented Dolt commands, never tokens on argv; validate the configured destination without printing secret-bearing URL components.

Serialize local collection/commit and sync against the canonical database. Commit local batches, fetch/merge remote history, validate schema/identity invariants, commit a clean merge and push. Permit at most three fetch/merge/push attempts on rejected pushes, then report pending sync without discarding local data. Independently appended rows merge naturally; same-identity conflicts, ownership conflicts and incompatible schema versions stop with retained data. Never force push or blanket ours/theirs. Migration writes require explicit owner-controlled coordination; unsupported newer schema is read-only/refused without data mutation. Keep remote synchronization distinct from source-Git sync and Beads sync.

Acceptance must exercise two clones sharing project identity, distinct device IDs, offline writes, both sync orders, identical replay, rejected push retry, schema incompatibility, intentional conflicting identity, crash/replay and network outage. Reports expose local-only versus synchronized coverage; absence of remote data is never presented as global completeness.

## Dependencies and execution order

| Task | Prerequisites | Reason |
| --- | --- | --- |
| TASK-TUC-001 | none | Storage/identity foundation |
| TASK-TUC-002 | TUC-001 | Adapter contract and durable ingestion |
| TASK-TUC-003 | TUC-001 | Antigravity exact-conversation investigation and adapter; independent of other adapters |
| TASK-TUC-004 | TUC-002, TUC-003 | Supervision consumes all adapter contracts |
| TASK-TUC-005 | TUC-004 | Reports consume persisted attribution and lifecycle facts |
| TASK-TUC-006 | TUC-001 | Sync validates storage identities independently of launcher work |
| TASK-TUC-007 | TUC-005, TUC-006 | Package/docs and complete installed CLI |
| TASK-TUC-008 | TUC-007 | End-to-end unsigned acceptance |

Use full TASK- IDs when wiring materialized Beads. No edge to gate-session-usage, MES, or pending Claude effort: none is required to collect usage with explicit/unknown attribution. Consume optional future fields compatibly. Every prerequisite implementation must be integrated into develop before dependent worktree allocation.

## Risks / Trade-offs

- Antigravity interactive retrieval remains unverified → dedicated early adapter task with blocking discovery if the source cannot meet the contract; never claim all-runtime completion prematurely.
- Runtime schemas/streaming revisions evolve → versioned adapters, identity/replay fixtures and explicit incomplete coverage.
- Dolt overhead and database growth → batch commits, indexes, measured Pi acceptance; no unreviewed deletion/retention policy.
- Device clock skew/coarse sources → preserve source versus observation times and quality; do not infer exact hourly distribution.
- Immutable telemetry retains task identifiers → private owner-only state and independent remote, allowlisted export, no source-Git publication.

## Migration Plan

Ship helpers/docs through normal pinned init/update. Create the local owner-only store lazily on first collection or explicit initialization, retain source provenance on backfill, and never fabricate historical complexity. Update/remove preserves user-owned database/spool/identity and unrelated hooks. Export plus Dolt commit/backup supports recovery. Rollback payload leaves the store intact; older schema readers refuse newer versions. Acceptance is unsigned; the Product Owner signs separately.
