## 1. Statusline hint, preview and revert (#280 code part)

- [ ] TASK-USR-001 [standard] [~260 loc: below the 400-line Bead range; one cohesive revision of `nogg usage install-statusline`, and a split would leave the hint, the dry-run or the uninstall without a testable capability of its own] Per design Decisions 1-6 (#280 items 2-3): replace the Claude `unknown` hint with the one-line effect-plus-docs-link constant in `inspect_usage()` and the doctor quota NOTE; split `install_statusline()` into plan and apply and add `--dry-run` (diff, no writes); make a real install back up `settings.json` and write the restore record; add `nogg usage uninstall-statusline [--dry-run] [--json]` restoring only the `statusLine` key; wire both into the `usage` subparser in `scripts/nogg`; update `docs/usage-limits.md` (undo section, verifying step), `docs/commands.md` and the CHANGELOG Unreleased entry. Check: extend `scripts/usage-statusline.test.sh` and `scripts/usage-hints.test.sh` first and red, update the superseded assertions in `scripts/usage-unknown-visibility.test.sh`, add a docs-anchor assertion; the usage suites; scripts/test. Branch feat/. Commit in steps: hint, dry-run and backup, uninstall, docs.

## Dependency contract

A single task with no prerequisites and no dependents. Markdown order does not
block work. Docs items 1 and 4 of #280 shipped with TASK-BDS-012 and are not
repeated here.
