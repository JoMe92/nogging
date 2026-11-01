## Context

Two files carry the behavior: `scripts/nogg_usage.py` (`inspect_usage()`,
`install_statusline()`, `quota_freshness_notes()`) and `scripts/nogg` (the
`usage` subparser and dispatch). One task covers the whole change; its commits
follow the decisions below in order (hint, dry-run/backup, uninstall, docs).

## Decisions

### 1. One hint constant, one docs link

Add `CLAUDE_STATUSLINE_HINT` in `nogg_usage.py`, a single line of the form
`opt in with nogg usage install-statusline (installs a capture wrapper as the
statusLine in ~/.claude/settings.json; --dry-run previews it) — see
https://jome92.github.io/nogging/usage-limits/#claude-usage-is-unknown-by-default`.
It replaces the literal `run nogg usage install-statusline` in
`inspect_usage()` and in the missing-cache branch of `quota_freshness_notes()`
(`quota observation (claude): missing statusline cache — <hint>`).
`nogg usage`, the launch WARN (which appends each window's hint) and the
`unknown_policy_notes()` doctor NOTE keep their format; the hint stays advisory
and no gate decision changes. The URL uses the published site
(`url`/`baseurl` in `docs/_config.yml`), because a consumer checkout has no
`docs/` directory. A test asserts that the anchor's heading still exists in
`docs/usage-limits.md` so the link cannot rot silently. Superseded exact-string
assertions in `usage-hints.test.sh` and `usage-unknown-visibility.test.sh` are
updated in the same commit.

### 2. Plan, then apply

Split `install_statusline()` into `_plan_statusline_install(settings, wrapper)`
(reads settings, validates, returns the status, upstream command, new settings
object and rendered old/new settings text; all existing refusals stay and raise
the same `RuntimeError`s) and the existing write steps. `install_statusline(...,
dry_run=False)` returns the same result dict plus `dry_run` and, for a dry run,
`diff` (a `difflib.unified_diff` of the settings file text before and after,
labelled with the real path; a missing file diffs against empty). A dry run
performs no filesystem write at all, not even `mkdir`. CLI text output prints
`would install statusline capture at <wrapper>` (and `would compose with: <cmd>`
when applicable), then the diff; an already-installed state prints
`already installed; nothing would change`. `--json` prints the result dict.
`--dry-run` with no action is an argparse-level error, not a silent no-op.

### 3. Backup and restore record on a real install

Before replacing `settings.json`, a real install copies the existing file
byte for byte to `<settings>.nogging-install.bak` (mode 0600, overwritten by
each real install; a missing settings file has nothing to back up). It also
writes the restore record `<wrapper>.restore.json` (mode 0600):
`{"schema_version": 1, "settings_path": ..., "previous_statusline": <the
exact prior JSON value or null if the key was absent>, "installed_at": ...}`.
The wrapper path stays `$XDG_DATA_HOME/nogging/claude-statusline`, so the
record sits beside it. The idempotent "already installed" path writes neither.
Rationale: restoring the whole backup would also discard unrelated settings the
operator changed after installing, so uninstall restores only the `statusLine`
key; the backup is the safety net, the record is the source of truth for the
key. The wrapper's baked-in `UPSTREAM_COMMAND` is not enough on its own because
it loses other keys of a `statusLine` object (for example `padding`).

### 4. Uninstall

`uninstall_statusline(settings_path=None, wrapper_path=None, dry_run=False)`:

1. Resolve paths exactly like install (same `--settings` and `--wrapper-path`
   flags). Read settings with the same malformed/non-object refusal and manual
   instructions.
2. If `statusLine` is absent or its command does not reference the wrapper
   (the same `str(wrapper)` / `nogging/claude-statusline` test install uses),
   return `status: not_installed`, change nothing, exit 0, and name the wrapper
   if it still exists.
3. Otherwise determine the previous value: the restore record's
   `previous_statusline` when present and readable; else the legacy fallback
   for installs made before this change, read from the wrapper's
   `UPSTREAM_COMMAND` literal (`ast.literal_eval`): `{"type": "command",
   "command": <upstream>}` when set, key removed when empty. If neither source
   exists (wrapper deleted by hand, no record), refuse with manual steps
   (restore `statusLine` yourself; the install backup path is named when it
   exists) and change nothing.
4. Back up the current settings to `<settings>.nogging-uninstall.bak`, then set
   or delete only `statusLine` (every other key untouched, written atomically
   with the install writer's formatting), then delete the wrapper and the
   restore record. The usage cache is left alone and the message says so.
5. `dry_run=True` computes the same plan and prints the diff, writing nothing.
   The result dict carries `status` (`uninstalled`, `not_installed`),
   `restored` (the value put back or `null`), `backup_path`, and `diff` for a
   dry run. A second uninstall is `not_installed`.

### 5. CLI shape

`scripts/nogg` extends the `usage` positional `action` choices with
`uninstall-statusline` and adds `--dry-run`. Dispatch mirrors the existing
`install-statusline` branch: `RuntimeError` prints `nogg: <message>` to stderr
and exits 1; `--json` prints the result dict with sorted keys. `--dry-run` with
`--agent` queries or without an action is refused with a one-line usage error.

### 6. Tests and docs

Test discipline: extend `scripts/usage-statusline.test.sh` and
`scripts/usage-hints.test.sh` first and red, using scratch `CLAUDE_CONFIG_DIR`,
`XDG_DATA_HOME` and `XDG_CACHE_HOME` and never the operator's real settings.
Cases: dry-run leaves a fixture tree byte-identical (including no new
directories) and prints the diff; real install writes the backup and the
record; install then uninstall round-trips settings byte for byte for (a) no
prior statusline, (b) a string statusline, (c) a `{type, command, padding}`
object, with unrelated keys edited between install and uninstall preserved;
uninstall twice and uninstall on an untouched fixture are `not_installed`;
legacy install (no record) restores from the wrapper; malformed settings
refuse; `--json` shapes. Docs: `docs/usage-limits.md` replaces "There is no
uninstall command" with the command, the dry-run preview step in *Verifying
it* and the backup file names; `docs/commands.md` lists both forms; a
`CHANGELOG.md` Unreleased entry.

## Risks

- The hint is longer; the launch WARN repeats it for both windows. Accepted:
  it is advisory and the docs link is the point.
- A hand-edited `statusLine` that no longer references the wrapper is left
  alone by uninstall (`not_installed`); that is the safe side.
