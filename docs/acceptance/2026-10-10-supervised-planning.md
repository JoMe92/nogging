# Supervised planning — scoped execution evidence — 2026-10-10

This unsigned report covers `support-supervised-planning`, TASK-SSP-006
(`SPEC-o1eu`), issues #47 and #52. It records scoped implementation checks;
it does not provide human acceptance or a public release sign-off.

| Field | Value |
| --- | --- |
| Executor | Nogging Lead (fenced execution session) |
| Implementation commits | `b946a1f` (SSP-004), `a77e424` (SSP-005), on `develop` `acf7b6b` |
| Environment | Linux aarch64 (Raspberry Pi), local Git, tmux, Beads/Dolt |
| Runtimes | Claude Code 2.1.296 (live); codex-cli 0.162.1, Pi 0.85.0 installed but not run live |
| Scratch | Throwaway repo with a bare `origin`, Nogging installed from this branch, own Beads tracker |

## Issue #47 — a supervised Planning Agent session

The orchestrator, outside the execution fence, launched
`./scripts/nogg session launch --role planning --planning-id ssp6-claude3
--description scratch-lifecycle --agent claude --profile trusted` in the
scratch repo. The bare launch allocated
`plan/ssp6-claude3/scratch-lifecycle` from `origin/develop` and recorded the
`planning` role with no Bead. It recorded complete ownership (`session_pid`,
`session_pid_start`, `session_pid_ns`). It took no planning lock and made no
Beads change: only the closed `openspec.readonly` sentinel existed, and
`bd list` was empty.

The Lead then sent the kickoff. The planner ran the sequence itself:

1. `plan-begin` in its planning worktree. The canonical lock in the main
   checkout named `session_name` `sf-planning-ssp6-claude3-…`, its pane pid and
   process start, and `planning_id` `ssp6-claude3`.
2. While that lock was held, a second `plan-begin` from the main checkout was
   refused: `planning lock held by session sf-planning-ssp6-claude3-… on
   raspberrypi pid 909832; live ownership cannot be forced` (exit 1). The
   lock file's hash was unchanged.
3. Discovery review (none pending), then authoring `ssp6-claude-example` from
   the canned acceptance fixture and `validate`.
4. Planning commit `404685a docs(openspec): add ssp6-claude-example` with the
   `Nogging-Writer: planning` trailer, **before** materialize.
5. `materialize ssp6-claude-example` created two Beads (`TASK-SSPC-001`,
   `TASK-SSPC-002`). `bd dep add` explicitly made 002 blocked by 001, and
   `bd ready` listed only 001.
6. `git merge --ff-only` in the main checkout: `develop` moved
   `f81ce6b..404685a`, with no push.
7. `worktree cleanup` retired the clean, integrated planning worktree and its
   branch. It left the two earlier aborted planners' worktrees untouched.
   The first attempt passed a record path; the command accepts the record file
   name.
8. `plan-end` from the surviving main checkout released the lock and restored
   the sentinel. Main checkout status was clean, and `validate` returned 0.

The planner claimed no Bead and did no implementation work. `session stop`
after `plan-end` left the closed boundary as it was. The supervised-planning
regressions (`planning-role`, `planning-kickoff`, `session`,
`repository-state`) cover Codex/Pi parsing, kickoff and lock ownership
offline.

## Issue #52 — scoped child launches under Claude auto mode

`./scripts/nogg session` launch/send/kickoff/stop/list/log/watch are granted
only to Lead and orchestrator effective settings. The bounded live probe used
Claude 2.1.296 with `--permission-mode auto`, inert `scripts/nogg` and `codex`
stubs, and three runs per condition:

| Condition | `nogg session launch` | direct `codex exec` fallback |
| --- | --- | --- |
| scoped effective settings | ran 3/3 | classifier-denied 1/3, allowed 2/3 |
| no scoped rules (control) | ran 3/3 | allowed 3/3 |

Classifier verdicts are not deterministic. The scoped rules make the
supervised path predictable. The prompts and the security model, not the
classifier, are what keep direct agent invocation out.

## Observed limits (recorded as Beads discoveries)

- A planner launched *from a fenced execution session* records
  `session_pid_start: None`, because host PIDs are invisible in the fence's
  PID namespace. Its `plan-begin` then refuses, safely. Launch should refuse
  or capture ownership host-side.
- Claude's workspace-trust dialog is not prepared for a worktree outside a
  trusted repository. Kickoff typed into the dialog and the session exited.
  For this scratch, the operator accepted trust once, deliberately.
- The execution fence mounts `openspec/` read-only, so `git rebase` across
  OpenSpec changes fails inside a Lead session.
- `scripts/test` is not hermetic against a parent session's `NOGG_*`
  variables.
- Codex and Pi planners were not run live in this pass. The Codex
  workspace-write sandbox's read-only `.git` is pending a Product Owner
  decision.

| Validation | Result / reproducible entry point |
| --- | --- |
| Scoped permissions, doctor notes, preservation | pass — `bash scripts/supervised-launch-permissions.test.sh` |
| Planning flow on every surface and installed copy | pass — `bash scripts/planning-docs.test.sh` |
| Live supervised Claude planning lifecycle | pass — scenario above |
| Live #52 auto-mode probe | observed — table above |
| Complete source and installed-consumer suite | pass — `bash scripts/test` with `NOGG_*` session variables unset |

Temporary logs are host-local diagnostic evidence. The checked-in tests and
the scenario details above provide the durable reproduction path. The human
sign-off remains open.

Signed-off-by:
