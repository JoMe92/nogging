## 1. Statusline hint, preview and revert (#280 code part)

- [x] TASK-USR-001 [standard] [~260 loc: below the 400-line range; one cohesive CLI revision, a split leaves no testable half] Per design Decisions 1-6 (#280 items 2-3): one-line effect-plus-docs-link Claude hint, `install-statusline --dry-run` with settings backup and restore record, `uninstall-statusline`, docs and CHANGELOG. Check: usage-statusline and usage-hints suites first and red; scripts/test. Branch feat/.

## Dependency contract

A single task with no prerequisites and no dependents. Markdown order does not
block work. Docs items 1 and 4 of #280 shipped with TASK-BDS-012 and are not
repeated here.
