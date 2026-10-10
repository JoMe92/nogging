# Session model selection — scoped execution evidence — 2026-10-10

This unsigned report covers `configure-session-models`, TASK-SCM-004
(`SPEC-vg5c`), the live acceptance for issue #51 model selection. It is a
targeted installer/session acceptance run, not the complete product
acceptance runbook or public-release sign-off.

## Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-10-10 |
| Host platform | Linux aarch64 (`raspberrypi`) |
| Executor | Nogging Lead |
| Implementation baseline | `268ba37ad5063eb03cf753583c69773ea8a4ed1f` (develop after PR #79) |
| Prerequisite commits | `11edb44` (SCM-002, PR #78), `4acecde` (SCM-003, PR #79) |
| Package metadata | `nogg` 2.1.0; unreleased checkout, not a new published tag |
| Node / npm | v22.23.2 / 10.9.8 |
| Python / Git | 3.13.5 / 2.47.3 |
| Bash / tmux | 5.2.37 / 3.5a |
| Codex CLI (live probe) | `codex-cli 0.162.1`, model `gpt-6.1-sol`, effort `low` |
| Claude Code (this session) | 2.1.296 |
| Distribution path | `npm pack --ignore-scripts`, extract archive, run packaged `bin/cli.js` |

## Payload inventory

`npm pack --ignore-scripts --dry-run --json` reports 98 files at the baseline.

| Helper | Bytes | SHA-256 |
| --- | ---: | --- |
| `scripts/nogg` | 251337 | `cd29c5313d8395ceebff5988039ed6b66cc8cb11cd442567cdf943f3101449b2` |
| `scripts/session-launch` | 14825 | `8afee78079fda7e29dc2cd6758018155c40c55ecfd6eda00ee94f03bee813545` |

## Installed-payload model-selection scenarios

`scripts/packed-model-selection.test.sh` installs the packed archive into a
fresh consumer (path with spaces), uses stub Claude/Codex/Pi runtimes and stub
Beads with real Git and tmux, and drives the installed `scripts/nogg`:

| Scenario | Result | Evidence |
| --- | --- | --- |
| Claude `--model` overrides profile model | pass | runtime argv carries `--model claude-sonnet-5-5`, profile model absent; record/list source `launch` |
| Claude profile model | pass | argv `--model claude-opus-5-5`; source `profile` |
| Claude legacy profile | pass | no `--model` in argv; list shows `runtime-default` |
| Codex `--model` override with profile effort | pass | argv `--model gpt-6-luna`; list `gpt-6-luna effort=high`, source `launch` |
| Codex profile reasoning effort | pass | argv contains contiguous `-c model_reasoning_effort="high"`; source `profile` |
| Codex legacy profile | pass | no `--model`; `runtime-default` |
| Pi `--model` | pass | argv `--model pi-model-x`; source `launch` |
| Unsupported effort (`turbo`) | pass | refuses naming `model_reasoning_effort`; no tmux session, no record |
| No mutation | pass | SHA-256 of every profile file and of user-global `~/.claude/settings.json`, `~/.codex/config.toml`, `~/.pi/agent/settings.json` unchanged across each launch |

## Live sandboxed Codex worktree lifecycle probe

One real Codex session (`sf-lead-spec-vg5c-20261010t211108-8f45`) was launched
through `scripts/nogg session launch --agent codex --model gpt-6.1-sol` with a
`workspace-write` / `approval never` / `network_access = true` profile carrying
`model_reasoning_effort = "low"`, in a dedicated detached worktree of this
repository with `openspec/` as a read-only root. The record shows
`requested_model gpt-6.1-sol`, `reasoning_effort low`, `model_source launch`,
which is the #51 model selection reaching a live runtime. Codex ran a
model-free probe script once and reported (Codex v0.162.1, 11,382 tokens):

| Step | Result |
| --- | --- |
| `git status` | PASS |
| write a worktree file | PASS |
| `git add` | PASS |
| `git commit` | PASS |
| `git worktree add` (nested) | PASS |
| `git worktree remove` | PASS |
| `bd show` (read) | PASS |
| `bd update --append-notes` (write) | PASS — the note is visible on `SPEC-vg5c` |
| `git fetch origin develop` | PASS |

### How `.git` and `.beads` access was obtained

These passes are not evidence that the default sandbox reaches shared state on
its own:

- **`.git`**: a linked worktree's index, refs and objects live in the main
  checkout's `.git`, outside the workspace. The launch passed the main
  `.git` and its `worktrees/<name>` directory as explicit `--writable-roots`;
  without that grant `workspace-write` cannot commit from a linked worktree.
- **`.beads`**: this repository runs `dolt.shared-server: true`. `bd` talks to
  a shared Dolt server under `~/.beads/shared-server` over localhost, so the
  read and write depend on `network_access = true`, not on `.beads/` being a
  writable root. A `restricted` (network off) Codex profile was not probed and
  is not claimed to reach Beads.
- `git fetch` likewise depended on `network_access = true`.
- The launcher warned that this Codex build has no plain-launch
  `--sandbox-state-readable-root`; `openspec/` read-only for Codex therefore
  rests on the `.codex/rules/` execpolicy deny and the pre-commit boundary
  hook, as the launcher's own warning states.

Only the `live-trusted` level was exercised, deliberately: the Codex 5h usage
window was at about 80% used, so one probe session and no implementation work
was run.

## Validation results

| Check | Result | Evidence |
| --- | --- | --- |
| Complete source suite | pass | `scripts/test` with `NOGG_*` and `NOGGING_ROOT` cleared: all script tests passed |
| Installed model selection | pass | table above |
| Live Codex worktree lifecycle | pass (with explicit grants) | table above |
| Whitespace validation | pass | `git diff --check` |

## Scope

With TASK-PSC-006 (`docs/acceptance/2026-10-09-session-payload-contract.md`)
covering the installer half and this run covering model selection, both
evidence prerequisites for #51 are recorded. No GitHub issue was closed
automatically; closing #51 is left to the Product Owner. The probe's throwaway
worktree and its `probe live-trusted` commit were never pushed. No real-agent
Claude or Pi model selection is claimed beyond the stub-runtime argv checks.

## Sign-off

Signed-off-by:
