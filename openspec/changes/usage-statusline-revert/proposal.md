## Why

Source: GitHub issue [#280](https://github.com/JoMe92/nogging/issues/280)
(Bead SPEC-ecl6). `nogg usage --agent claude` reports
`unknown (missing usage source)` and hints only `run nogg usage
install-statusline`. That command rewrites the global Claude Code
configuration (`~/.claude/settings.json`) and writes a wrapper script, yet an
operator can neither see what it would change before agreeing to it nor undo it
with a command. The documentation half of #280 (the usage-limits section,
verification and manual undo steps) is already merged; this change is the code
half.

## What Changes

- The Claude `unknown` hint shown by `nogg usage`, the unknown-admitted launch
  WARN and the `doctor` quota NOTE states the effect of the opt-in in one line
  and links the docs section `usage-limits#claude-usage-is-unknown-by-default`,
  instead of only naming the command.
- `nogg usage install-statusline --dry-run` prints the intended change (wrapper
  path, composed upstream command, unified diff of `settings.json`) and writes
  nothing: no wrapper, no settings, no backup, no directory.
- A real install now backs up `settings.json` and records the previous
  `statusLine` in a restore record next to the wrapper.
- New `nogg usage uninstall-statusline [--dry-run] [--json]` restores the
  previous `statusLine` (or removes the key if there was none), backs up the
  settings first, deletes the wrapper and the restore record, and is a no-op
  when the capture is not installed.

**Not changed:** the capture wrapper's behavior, the cache format, the gate
decision logic, `usage_gate.on_unknown` and the `unknown` status itself.
Uninstall leaves the usage cache in place (it expires by `stale_seconds`).

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `session-usage`: the Claude remediation hint states the effect and links the
  docs; the statusline capture becomes previewable and reversible.

## Impact

- `scripts/nogg_usage.py`: `install_statusline()` split into a pure plan and an
  apply step, a new `uninstall_statusline()`, the Claude hint constant used by
  `inspect_usage()` and `quota_freshness_notes()`.
- `scripts/nogg`: the `usage` subparser (`uninstall-statusline`, `--dry-run`)
  and its dispatch.
- Existing suites updated for the new wording: `scripts/usage-hints.test.sh`,
  `scripts/usage-unknown-visibility.test.sh`, `scripts/usage-statusline.test.sh`.
- Docs: `docs/usage-limits.md` (undo section), `docs/commands.md`,
  `CHANGELOG.md`. No new config key, no authority change, no dependency.
