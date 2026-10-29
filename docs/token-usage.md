# Token usage accounting

Nogging keeps a private, local record of the tokens each supervised session
consumed, and lets you query it by time window, model, task and complexity. It
counts tokens only: there is no price, no billing figure and no quota percent
here. Rate-limit observation and quota admission are a separate feature — see
the [usage limits guide](https://jome92.github.io/nogging/usage-limits/) and
the [launch usage
gate](https://jome92.github.io/nogging/running-work-in-sessions/#launch-usage-gate).

## What ships and where state lives

- **Helpers** are installed by `init`/`update` as `scripts/lib/token_usage_*.py`
  and are driven only through `scripts/nogg token-usage ...`. They are
  Nogging-owned and overwritten on update; `remove` deletes them.
- **State** is created lazily under `.nogging/state/token-usage/` of the
  canonical main checkout (shared by every linked worktree on the host):
  `database/` (a local Dolt repository, separate from Beads), `spool/` and
  `collector/`. Nothing is created by install, `update` or a read-only command
  such as `status`; the first collection or `import` creates it with
  owner-only (`0700`) directories. It is gitignored and never part of the
  source repository.
- **Requirements:** `dolt` on `PATH` (already required for Beads) and Python 3.
  No service or timer is installed; collection happens during supervised
  session activity and on explicit command.

## Commands

```bash
./scripts/nogg token-usage status [--json]     # store, pending spool, sync freshness
./scripts/nogg token-usage collect [--session NAME] [--json]   # explicit catch-up
./scripts/nogg token-usage report [--from T --to T] [--group-by hour|day|session|bead] \
    [--model M] [--task T] [--bead B] [--complexity C] [--runtime R] [--json]
./scripts/nogg token-usage session <name-or-segment> [--json]
./scripts/nogg token-usage export [--all] [--from T --to T] > usage.jsonl
./scripts/nogg token-usage import --file usage.jsonl
./scripts/nogg token-usage sync [--remote NAME]   # trusted operator only
```

Windows are UTC and half-open (`from` inclusive, `to` exclusive). Unknown
coverage (a runtime or source that reports no usage) is reported as unknown,
never as zero. Complexity is recorded only when supplied at launch; historical
sessions are never given a guessed complexity.

Every local Dolt query behind `report`, `session`, `export`, `import` and
`status` has a time limit, `token_usage_query_timeout_seconds` in
`.nogging/config.json` (default 30). A busy store (for example, one a collection
or sync is writing) or a very large store fails fast with
`local Dolt query timed out after 30s` and the remedy, instead of hanging.
`status` counts facts without loading them.

## Tokens per Bead: the efficiency metric

`report --group-by bead` gives one row per Bead and runtime (agent). A Bead
worked by several runtimes also gets an `all` total line, and usage with no
Bead at launch is grouped under `-`. Each row shows:

| Column | Meaning |
| --- | --- |
| `FRESH_IN` | Input not served from the prompt cache: input minus cache read. |
| `CACHE_READ` | Input re-read from the prompt cache. |
| `CACHE_WRITE` | Input written to the cache (Claude). It is part of `FRESH_IN`. |
| `OUTPUT` | Output, including thinking and reasoning tokens. |
| `TOTAL` | All input (cached and fresh) plus output. |
| `COMMITS`, `PROD_LINES` | The Bead's commits and their production lines (see below). |
| `FRESH/LINE`, `OUT/LINE`, `TOTAL/LINE` | Those tokens divided by production lines. |

`--json` carries the same fields: `work` for the tokens, plus `commits`,
`production_lines`, `test_lines` and `per_production_line`. A `beads` list
holds the per-Bead totals.

**Fresh input per runtime.** The stored input always includes cache reads, so
fresh input is input minus cache read for every runtime:

- **Claude.** Stored input is uncached input + cache read + cache write.
  Fresh input is uncached input plus cache write, which is the new context
  the turn added.
- **Codex.** The provider's input already includes the cached input. Fresh
  input is input minus cached input. Codex reports no cache write.
- **Antigravity.** The provider's input excludes cache reads, and the store
  adds them back. Fresh input is the provider's own input.

If a source can't prove the split (no cache-read counter, or a cache read
without a flag saying input includes it), the sum is marked `+?` and the value
is never guessed.

**Production lines.** Nogging finds every non-merge commit whose subject
carries the literal `[<bead-id>]` token. It searches all local and
remote-tracking branches and tags, but not stash, notes or Beads'
`refs/dolt/*`. A rebased or cherry-picked copy (same author time and subject)
counts once. A commit naming several Beads counts for each of them.

Production lines are added plus deleted lines from `git --numstat`, with
renames detected and binary files counted as 0. Some files are left out:

- **Tests** (`test_lines` in `--json`): `test/`, `tests/`, `__tests__/`, `fixtures/` and
  `testdata/` directories, and `*.test.*`, `*.spec.*`, `*_test.py`,
  `*_test.go` and `test_*.py` files.
- **Generated and planning files**: `openspec/`, `.beads/` and lockfiles such
  as `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Cargo.lock`,
  `poetry.lock`, `uv.lock` and `go.sum`.

Docs and all other files count as production lines, as in `task_sizing`
estimates.

The commits are not limited to the report window, so make `--from`/`--to`
cover the Bead's whole run. The git fields are null (`-` in text) when git is
unavailable or the Bead has no commits. The per-line fields are also null
when the Bead has no production lines, or when a row has no usage events.

**Reading it.** Fresh input and output per production line are the cost of
the work itself. Cached input grows with every turn spent waiting or polling,
and with the size of the context being re-read, so a high `CACHE_READ` with
low `FRESH/LINE` points to idle or long-context sessions rather than to
expensive work. In a 208-Bead sample, Beads of 500–1000 production lines cost
the fewest tokens per line.

```bash
./scripts/nogg token-usage report --group-by bead --from 2026-10-01 --to 2026-11-01
./scripts/nogg token-usage report --group-by bead --bead SPEC-abc --from 2026-10-01 --to 2026-11-01 --json
```

## Update, remove and rollback

`update` and `remove` touch only the helper and doc files above. They never
read, rewrite or delete `.nogging/state/token-usage/`, your Beads data, your
OpenSpec files or unrelated hooks and settings. Rolling the payload back
leaves the store intact; an older reader refuses a newer schema rather than
guessing, so upgrade the payload to read it.

## Recovery and export

The store is the source of truth; the JSONL export is the recovery format.

1. Take an export periodically: `token-usage export --all > usage.jsonl`.
   Exports carry allowlisted fields only, no transcripts or prompts.
2. To recover after losing the database, reinstall, then
   `token-usage import --file usage.jsonl`. Import adopts the exported
   project identity and is idempotent: re-importing identical facts is a
   no-op.
3. The local Dolt repository can also be backed up as a directory while no
   collection runs; use `status` to see pending or quarantined batches first.

If `status` reports quarantined batches, the facts conflicted with already
stored history; they are kept for inspection, never silently dropped.

## Syncing between devices

Usage has its own optional remote, independent of the source repository and of
Beads. Set `token_usage_remote` in `.nogging/config.json` (default `origin`)
and run `token-usage sync` from a trusted operator or orchestrator session. It
makes a bounded number of fetch/merge/push attempts and reports conflicts; it
never force-pushes. Without a remote the store works fully offline.
