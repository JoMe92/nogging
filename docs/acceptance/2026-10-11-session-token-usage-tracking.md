# Session token usage tracking — scoped execution evidence — 2026-10-11

This unsigned report covers `session-token-usage-tracking`, TASK-TUC-008
(`SPEC-eudc`): full isolated verification plus packed and live acceptance of the
usage collector, reports, export/import and independent-device sync. It is an
implementation evidence report only; it is not a human acceptance sign-off or a
public-release authorization. The Product Owner signs separately.

## Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-10-11 |
| Host | Linux aarch64 (Raspberry Pi, `raspberrypi`) |
| Executor | Nogging Lead (supervised Claude session) |
| Baseline | `a8cb797` (develop after PR #121, TASK-TUC-007) |
| Prerequisites | TASK-TUC-001..007 integrated in develop |
| Runtimes observed | Claude Code 2.1.296, Codex CLI 0.162.1, Antigravity 1.3.3, Pi 0.85.0 (host only; no Pi adapter in scope) |
| Dolt / Node / Python | 2.3.1 / v22.23.2 / 3.13.5 |
| Distribution path | `npm pack --ignore-scripts`, extract, packaged `bin/cli.js init` into scratch consumers |

Helper payload installed from the archive: `scripts/lib/token_usage_{adapters,
antigravity,collect,report,store,sync}.py`, no tests, no bytecode.

An earlier execution session for this Bead crashed (tmux server restart) after
writing a draft of this report. Every figure below was **re-measured** by the
recovering session; nothing was carried over from the draft.

## Method and isolation

- The full suite ran as `scripts/test` with every inherited `NOG_*`/`NOGG_*`
  and `NOGGING_ROOT` variable removed from the child environment.
- Live evidence was gathered in **scratch consumers** (fresh `git init` plus
  packed `init`), never in the operator's real
  `.nogging/state/token-usage/`. Supervised session records were *copied*
  (read-only) from this host into the scratch consumers, so the collector read
  the real Claude, Codex and Antigravity local sources of those sessions. No
  new model quota was spent by acceptance itself, and no real session record,
  runtime source or Beads data was modified.
- The 16 sessions are the four host sessions that carry a `usage_attribution`
  snapshot (one per task, spanning all three runtimes) plus the newest four
  retired sessions per runtime without one. Retired sessions pre-date
  attribution; they have no task or complexity and are reported as `unknown`,
  never guessed.
- Collection was driven to completion with repeated `token-usage collect`
  passes (each pass drains for a bounded time) until nothing was spooled.

## Full isolated suite

`scripts/test` with the delivery-session environment removed:
**85 of 85 test scripts `PASS`, 0 `FAIL`, final line
`Nogging: all script tests passed`, exit status 0.** This run executed on the
branch at `a8cb797` plus this report only (no product-source change), and ran
concurrently with the first collection passes below.

## Nonzero usage for all three runtimes

16 sessions, `token-usage collect` drained until nothing pending, **no
quarantine, no store error**. Report window 2026-10-01..2026-10-12 UTC,
`completeness: complete` for all 2,594 usage events.

| Runtime (`--runtime`) | Events | Models (source-reported) | Input tokens | Output tokens | Cache-read tokens |
| --- | ---: | --- | ---: | ---: | ---: |
| Claude | 568 | `claude-opus-5-5` 441, `claude-sonnet-5-5` 127 | 102,539,852 | 426,772 | 101,591,337 |
| Codex | 499 | `gpt-6-luna` 278, `gpt-6.1-sol` 221 | 54,164,660 | 104,600 | 53,474,176 |
| Antigravity | 1,527 | `gemini-3.8-flash-n` (name as reported by the source) | 197,867,287 | 624,349 | 190,203,932 |

Per-source diagnostics were honest rather than silent:
`generation_error_without_usage` for two Antigravity sessions whose generation
failed with no usage record. Neither produced fabricated counts.

## Model, task and complexity queries

Same window, `--group-by day`, filters as named:

| Query | Events | Result |
| --- | ---: | --- |
| `--complexity standard` | 705 | `claude-sonnet-5-5` 127, `gemini-3.8-flash-n` 300, `gpt-6-luna` 278 |
| `--complexity complex` | 325 | `gemini-3.8-flash-n` only |
| `--complexity unknown` | 1,564 | `claude-opus-5-5` 441, `gemini-3.8-flash-n` 902, `gpt-6.1-sol` 221 |
| `--task TASK-CRE-003` | 127 | `claude-sonnet-5-5` |
| `--task TASK-CRE-004` | 278 | `gpt-6-luna` |
| `--task TASK-MES-006` | 300 | `gemini-3.8-flash-n` (standard) |
| `--task TASK-GSU-004` | 325 | `gemini-3.8-flash-n` (complex) |
| `--model gpt-6-luna` | 278 | Codex only |
| `--model claude-sonnet-5-5 --task TASK-CRE-003 --complexity standard` | 127 | filters compose (AND) |
| `--group-by hour`, 13:00..16:00 UTC | 282 + 533 + 374 | adjacent half-open hour buckets, no overlap |

This demonstrates model-by-task-by-complexity comparison from real data.
Complexity values come from `selection_tier` snapshots recorded at launch; the
1,564 events with no snapshot are counted under `unknown` in coverage
(`unknown_task` = `unknown_complexity` = 1,564, `unknown_model` = 0).

## Two-device convergence

Two scratch consumers with distinct device identities and a shared project
identity, one shared usage remote (a local Dolt `file://` remote). The second
device is a `dolt clone` of the remote, which yields a new device UUID.

| Step | D1 | D2 |
| --- | --- | --- |
| Baseline | 4 attributed sessions, 1,030 usage events, pushed (1 attempt) | cloned, 1,030 |
| Offline writes | +2 Codex sessions (+133 events) | +2 Claude, +2 Antigravity sessions (+638 events) |
| Copied source | exported all facts (1,187 facts) | `token-usage import` of that export: 145 added, remainder already present |
| Before sync (usage events) | 1,163 | 1,801 |
| Sync order D2, D1, D2, D1 | all `synchronized`, 1 attempt, no conflicts | |
| After sync | 1,801 usage / 10 segments / 10 attributions | identical |
| Report totals | 1,801 events, 264,012,346 input / 915,879 output / 257,400,118 cache-read tokens | identical |

Effective usage equals baseline + both devices' independent writes
(1,030 + 133 + 638 = 1,801): the copied source was counted once and the
fourth sync was an idempotent replay. The sorted exports of the two devices
(1,864 lines) differ in exactly one line, the `exported_at` header.

### Competing source ownership (observed, spec-conformant stop)

Two further behaviours were exercised in a second device pair and are
reported because they affect what an operator will see:

- **Source already held by the remote, collected again on the other device.**
  D2 cloned a store that already contained a supervised Codex session, then
  collected that session's source itself. Its facts were quarantined as
  `source ownership conflict; explicit ownership transfer required`
  (8 quarantine files, retained for inspection, `status` reports them) and
  the session was counted once.
- **Same new source collected independently offline on both devices.** The
  device that synchronized first pushed cleanly; the second device's sync
  stopped with state `conflict` (`session_segments` 1, `source_owners` 2),
  `merge aborted, both histories retained`, remote untouched, identical on
  retry. This is the specified outcome for competing source ownership (the
  design: one device owns each source stream).

Not re-exercised live: rejected-push retry, remote outage, identity collision
and newer-remote-schema refusal. These are covered by the offline fixtures in
`scripts/lib/token_usage_sync_test.py`.

## Pi host timing and size measurements

Measured on this Raspberry Pi with the suite finished (quiet host), cold
process per command, wall time:

| Operation | 1,801 events (10 sessions) | 2,815 events (19 sessions) |
| --- | ---: | ---: |
| `dolt sql -q "select 1"` (baseline) | 0.1 s | 0.2 s |
| `token-usage status` | 4.5 s | 9.8 s |
| `report --group-by day` | 4.8 s | 9.9 s |
| `report --group-by session` | 4.9 s | 9.2 s |
| `report` with `--complexity` filter | 4.8 s | 8.9 s |
| `export --all` | 5.1 s | 8.4 s |
| `collect` with nothing new | 0.7 s | 1.0 s |
| `sync` (push or no-op merge) | 2–4 s | — |
| Store on disk (`database/`) | 67 MB | 188 MB |

A first `collect` imports at most about 20–25 s of work per pass (about
450–800 events); the 16-session set drained in 5 passes.

## Findings

- **Read latency (discovery).** Every read command costs 4.5–10 s for two to
  three thousand events although a single Dolt query is 0.1–0.2 s, and the
  cost grows faster than the event count (1.6x events, 2.2x time). The CLI
  loads all facts per call, so a long-lived store gets slower. No regression
  test fails; this is a measured, unbudgeted cost and should be a planned
  follow-up before heavy use.
- **Store growth (discovery).** About 37–67 KB of disk per usage event.
  Retention is explicitly out of scope; the design's "database growth" risk is
  real at this rate.
- **Whole-host backfill is large.** Pointing the collector at all 99 session
  records of this host produced a backlog of about 9,100 spooled facts
  (214 batches) after one pass. It was abandoned in favour of the bounded
  16-session set; operators should expect many passes on first use.
- **Conflict recovery is undocumented (discovery).** A competing-ownership
  stop aborts the whole merge, so the stopped device's *unrelated* facts also
  stay local until the owner resolves it, and `docs/token-usage.md` names
  neither the one-owner-per-source rule nor a recovery path (there is no
  ownership-transfer command in scope).
- **Model name.** The Antigravity source reports `gemini-3.8-flash-n`; the
  collector stores it verbatim, so it does not match the table's
  `gemini-3.8-flash-<level>` names. Reports group by what the source said.

## Limits of this evidence

- Unsigned; human acceptance is separate.
- Usage came from existing supervised sessions on this host, not from freshly
  launched probe sessions; live quota was deliberately not spent.
- The Claude/Codex/Antigravity numbers are token consumption as reported by
  the sources, not cost or quota percent.
- Event counts of still-running sessions grow between runs; each table is one
  consistent run, and figures from different tables are not comparable.
- Pi timing is a measurement on one host at two store sizes, not a guarantee.
