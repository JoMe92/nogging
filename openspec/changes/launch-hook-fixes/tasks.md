## 1. Independent fixes (fix/, feat/, refactor/ — parallel, no prerequisites)

- [x] TASK-LHF-001 [standard] Per design Decisions 1-2 (#184): count only blocking edges (`dependency_type` `blocks` or absent, status not closed) in `unmet_dependencies()` and scripts/hooks/pre-tool-use-lead-launch-guard, so a child of an open epic launches while open blockers still refuse. Branch fix/. Check: scripts/launch-blocking-edges.test.sh (new); scripts/hooks/pre-tool-use-lead-launch-guard.test.sh; scripts/test.

- [x] TASK-LHF-002 [standard] Per design Decisions 1 and 3 (#195): add an agent-binary preflight before any launch side effect and a bounded post-start settle check that fails non-zero with the startup-log tail, no kickoff hint, no chained `--kickoff`. Own the preflight/start region of `_session_launch()`. Branch feat/. Check: scripts/session-launch-agent-binary.test.sh (new); scripts/test.

- [x] TASK-LHF-003 [routine] Per design Decisions 1 and 4 (#204): write the Claude Stop/Notification hook commands with an absolute, shell-quoted launch-time path to scripts/nogg; update the old relative assertion in scripts/session-observability.test.sh. Own `OBSERVABILITY_HOOKS` only. Branch refactor/. Check: scripts/session-hook-absolute-path.test.sh (new); scripts/session-observability.test.sh; scripts/test.

## Dependency contract

No blocking edges: LHF-001, LHF-002 and LHF-003 are independent and run in
parallel. Markdown order does not block work. Branches are
<prefix>/launch-hook-fixes with each task's prefix above (fix/, feat/,
refactor/); each uses its own worktree. The three tasks edit different regions
of scripts/nogg, so merges may need a trivial rebase but never a shared lane.
