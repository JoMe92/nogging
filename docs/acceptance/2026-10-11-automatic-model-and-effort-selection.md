# Automatic model and effort selection — scoped execution evidence — 2026-10-11

This unsigned report covers `automatic-model-and-effort-selection`, TASK-MES-006
(`SPEC-2u2m`), the live acceptance and verification for automatic model and effort
selection across Claude, Codex, and Antigravity. It is a scoped implementation and
acceptance report; it does not provide human acceptance sign-off or public release
authorization.

## Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-10-11 |
| Host platform | Linux aarch64 (`raspberrypi`) |
| Executor | Nogging Lead (`lead@nogging.bot`) |
| Implementation baseline | `d36532386fe8cb98fa5aa333a4bf9dd2462e245c` (develop after PR #113) |
| Prerequisite commits | `e057391` (MES-001), `32b2a11` (MES-002, PR #96), `0c50a40` (MES-003, PR #97), `1eb9804` (MES-004) |
| Package metadata | `nogg` 2.1.0; unreleased checkout, not a new published tag |
| Node / npm | v22.23.2 / 10.9.8 |
| Python / Git | 3.13.5 / 2.47.3 |
| Bash / tmux | 5.2.37 / 3.5a |
| Available Agent runtimes | Claude Code 2.1.296, Codex CLI 0.162.1, Pi 0.85.0, Antigravity 1.3.3 |
| Distribution path | `npm pack --ignore-scripts`, extract archive, run packaged `bin/cli.js` |

## Payload inventory

`npm pack --ignore-scripts --dry-run --json` reports 101 packaged files at this baseline:

| Helper | Bytes | SHA-256 |
| --- | ---: | --- |
| `scripts/nogg` | 313487 | `60b55795bfc3cd0dfd0e2720a39380cd5ad8e87506caf34036941b93df0188d3` |
| `scripts/session-launch` | 15394 | `422224933244e9159bea0c40c36182291d5dfdbebd14523af29407b31483b243` |
| `templates/model-selection.json` | 1827 | `ea4be514001df996ee0f8d0de12cb8930ba656997c2bb265d91694fc29ecad6e` |

## Packed init/update scaffold & model validation

Verified in `scripts/packed-model-selection.test.sh` against the packed npm package installed into a fresh consumer directory:

| Scenario | Result | Evidence |
| --- | --- | --- |
| Packed `init` scaffolds `.nogging/model-selection.json` | pass | Installed file is byte-for-byte identical to packaged template (`templates/model-selection.json`). |
| Packed `init` copies documentation | pass | Installed `docs/nogging/model-selection.md` exists and is populated. |
| Installed `scripts/nogg models check` passes | pass | Installed `nogg` validates the scaffolded `.nogging/model-selection.json`. |
| Consumer edits survive `update` | pass | Edits to `.nogging/model-selection.json` remain byte-for-byte identical across `cli.js update`. |
| `update` scaffolds absent table | pass | Removing `.nogging/model-selection.json` and running `update` re-creates it from the packaged template (`onUpdate: true`). |

## Installed-payload tier launch scenarios

All scenarios are exercised on the packaged consumer payload driving live tmux sessions with stub runtimes in `scripts/packed-model-selection.test.sh`:

| Scenario / Behavior | Result | Evidence |
| --- | --- | --- |
| Claude routine tier | pass | Runtime receives `--model claude-sonnet-5-5`; no effort flag emitted; notice `NOTE: tier routine Claude effort 'low' is not applied: Claude effort forwarding is pending change support-claude-reasoning-effort` emitted; record carries `selection_tier: routine`; list shows `claude-sonnet-5-5 tier=routine`. |
| Codex standard tier | pass | Runtime receives `--model gpt-6-luna` and contiguous `-c model_reasoning_effort="medium"`; record carries `selection_tier: standard`, `reasoning_effort: medium`; list shows `gpt-6-luna effort=medium tier=standard`. |
| Codex complex tier | pass | Runtime receives `--model gpt-6.1-sol` and contiguous `-c model_reasoning_effort="high"`; record carries `selection_tier: complex`, `reasoning_effort: high`; list shows `gpt-6.1-sol effort=high tier=complex`. |
| Antigravity complex tier (`--agent agy`) | pass | Runtime receives `--model gemini-3.8-flash-high`; no reasoning effort flag emitted; record carries `agent: antigravity`, `selection_tier: complex`; list shows `gemini-3.8-flash-high tier=complex`. |
| Explicit `--model` beats tier model | pass | Launch with `--tier standard --model gpt-6.1-sol` passes `--model gpt-6.1-sol` while tier still supplies effort `medium`; list shows `gpt-6.1-sol effort=medium tier=standard`. |
| Tier beats profile model and effort | pass | Launch with profile having `gpt-6-sol` and effort `high` plus `--tier routine` selects tier model `gpt-6-luna` and effort `low`; list shows `gpt-6-luna effort=low tier=routine`. |
| Unsupported effort refusal | pass | Launch with profile effort `turbo` is refused naming `model_reasoning_effort`; no tmux session or session record created. |
| Unknown tier refusal | pass | Launch with `--tier trivial` is refused naming `is not a model-selection tier`; no tmux session or session record created. |
| Pi tier refusal | pass | Launch with `--agent pi --tier routine` is refused naming `is not supported for agent 'pi'`; no tmux session or session record created. |
| Invalid table refusal | pass | Launch with corrupted table (missing `routine` tier) is refused naming `is invalid`; no tmux session or session record created. |
| Isolation & no settings mutation | pass | Profile files and user-global configuration files (`~/.claude/settings.json`, `~/.codex/config.toml`, `~/.pi/agent/settings.json`, and Antigravity `toolPermission`) are verified unmutated across all launches. |

## Read-only live models & doctor probe

Executed on the host checkout against live installed tools:

```
$ ./scripts/nogg models check
model-selection table /home/jome/src/nogging-spec-2u2m/.nogging/model-selection.json is valid (table_version 2026-10-11, 3 tiers x 3 agents)

$ ./scripts/nogg models
model-selection table_version=2026-10-11 researched_at=2026-10-11
routine   claude       model=claude-sonnet-5-5 effort=low
routine   codex        model=gpt-6-luna effort=low
routine   antigravity  model=gemini-3.8-flash-low
standard  claude       model=claude-sonnet-5-5 effort=high
standard  codex        model=gpt-6-luna effort=medium
standard  antigravity  model=gemini-3.8-flash-medium
complex   claude       model=claude-opus-5-5 effort=xhigh
complex   codex        model=gpt-6.1-sol effort=high
complex   antigravity  model=gemini-3.8-flash-high
  routine: Mechanical, fully specified, low blast radius.
  standard: A normal feature or bug Bead with a clear spec; use it when unsure between routine and standard.
  complex: Ambiguous or cross-cutting work, or any relaunch after a failed or stalled attempt.

$ ./scripts/nogg doctor
OK  git
OK  python3
OK  bd
OK  dolt
OK  session-launch helper contract
OK  session-log-writer helper contract
OK  OpenSpec filesystem boundary helper contract
NOTE  openspec write boundary: LOCKED
NOTE  compatibility baseline: Node 18/20/22, Python 3.9-3.13, Git 2.30+, Bash 4.4+, OpenSpec 1.11.x, Beads 1.2.x, Dolt 2.3.x (docs/nogging/compatibility.md)
NOTE  codex available
NOTE  agy available; baseline 1.3.2 has unsigned core live evidence; quota pending AGR-005
NOTE  pi available
...
```

Live inspection confirmed:
- Local Codex models cache contains both `gpt-6-luna` and `gpt-6.1-sol`.
- Local Antigravity CLI reports `gemini-3.8-flash-{low,medium,high}` available.
- Installed table version matches packaged template version `2026-10-11`.
- `doctor` reports zero drift NOTEs for the model-selection table.

## Validation results

| Check | Result | Evidence |
| --- | --- | --- |
| Complete source suite | pass | `scripts/test` with `NOGG_*` cleared, without `bd`: all script tests passed. |
| Packed model-selection suite | pass | `scripts/packed-model-selection.test.sh`: all scaffold, launch, precedence and refusal fixtures passed. |
| Clean whitespace | pass | `git diff --check`: no trailing whitespace or merge conflict markers. |

## Scope

This report completes acceptance verification for TASK-MES-006 under change
`automatic-model-and-effort-selection`. It verifies the table schema, installer
scaffold, CLI inspection, session launch tier resolution and provenance, doctor
catalog drift checks, and error handling across Claude, Codex, Antigravity, and Pi.

## Sign-off

Signed-off-by:
