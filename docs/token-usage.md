# Token usage accounting

Nogging keeps a private, local record of the tokens each supervised session
consumed, and lets you query it by time window, model, task and complexity. It
counts tokens only: there is no price, no billing figure and no quota percent
here (quota admission is a separate feature, see `running-work-in-sessions.md`).

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
./scripts/nogg token-usage report [--from T --to T] [--group-by hour|day|session] \
    [--model M] [--task T] [--complexity C] [--runtime R] [--json]
./scripts/nogg token-usage session <name-or-segment> [--json]
./scripts/nogg token-usage export [--all] [--from T --to T] > usage.jsonl
./scripts/nogg token-usage import --file usage.jsonl
./scripts/nogg token-usage sync [--remote NAME]   # trusted operator only
```

Windows are UTC and half-open (`from` inclusive, `to` exclusive). Unknown
coverage (a runtime or source that reports no usage) is reported as unknown,
never as zero. Complexity is recorded only when supplied at launch; historical
sessions are never given a guessed complexity.

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
