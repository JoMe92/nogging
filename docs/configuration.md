# Configuration reference

This page lists every key of `.nogging/config.json`: its type, its default and
what it does. It is for operators who tune a repository and for anyone who
needs to know what a key does before changing it. Every key is optional unless
the table says otherwise; an absent key takes the default shown.

`.nogging/config.json` is per checkout. The installer scaffolds it from
`templates/nogging-config.json` and `update` preserves the values you changed.
Keys the scaffold does not write (most of the session and usage keys) are read
with the default shown, so add one only when you want a different value. The
keys are grouped as identity and personas, sync, sessions, models, usage,
multi-machine, agent state and work sizing. The commands that read them are described in the
[command reference](commands.md).

## Identity and personas

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `name` | string | the repository name | Project name written by the installer. Informational. |
| `nogging_version` | string | the installed release | Release recorded by the installer. `update` reads it to pick the right baseline for upgrades; do not edit it by hand. |
| `beads_command` | string | `bd` | Executable used for every Beads call. Required by the scripts; change it only to point at a wrapper or a non-standard install path. |
| `personas` | object | the ten-entry roster | Commit identities per role (`planner`, `lead`, `orchestrator`, `sync`, `architect`, `ux-reviewer`, `backend-engineer`, `frontend-engineer`, `code-reviewer`, `test-runner`), each `{"name": …, "email": …}`. A missing or incomplete entry makes the command that needs it fail instead of committing under another identity. |
| `change_states` | array of strings | `["open", "done", "archived"]` | The lifecycle states a change directory moves through. Scaffolded for reference; the scripts do not read it. |

## Sync

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `sync_interval_seconds` | integer | `30` | Intended cadence of the sync pass. The scripts read it only as the base delay of the retry back-off when `sync_retry_base_seconds` is unset. |
| `sync_lock_ttl_seconds` | integer | `120` | A `sync.lock` older than this is stale and may be taken over. A fresh lock makes a second sync pass report contention and exit. |
| `planning_lock_ttl_seconds` | integer | `7200` | A `planning.lock` older than this is stale. While a fresh one is held the sync skips, so planning and sync never interleave. See [Failure recovery](failure-recovery.md). |
| `sync_max_attempts` | integer | `5` | How many consecutive transient failures the sync retries before it stops retrying and waits for you. |
| `sync_retry_base_seconds` | integer | `sync_interval_seconds` | First retry delay. Each further failure doubles it. |
| `sync_retry_cap_seconds` | integer | `1800` | Upper bound of the retry delay. |
| `sync_protected_branches` | array of strings | `["main", "develop"]` | Branches on which the timer-driven sync refuses to commit a mirror. `sync --now` is allowed on them; a merge, rebase, detached `HEAD` or fresh planning lock still skips. The first entry is also the default for `recover_base_branch`. |
| `recover_base_branch` | string | first entry of `sync_protected_branches`, else `main` | Branch that `recover` measures commits-since-fork and `LIMBO` Beads against. |
| `claim_stale_seconds` | integer | `14400` | A claimed Bead with no commit older than this is reported by `recover` as stale. Reported for attention only; it never changes the exit code on its own. |
| `state_dir` | path | `.nogging/state` | Directory under the main checkout that holds the worktree and rebase records. |

## Sessions

Session keys apply to `./scripts/nogg session` and `orchestrator`. See
[Running work in sessions](running-work-in-sessions.md) for the behaviour
behind them.

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `session_agent` | string | `claude` | Agent a launch uses when you pass no `--agent`. |
| `session_backend` | string | `tmux` | Terminal backend for launches without `--backend`: `tmux` or `herdr` (experimental). The `--backend` flag wins over this key. See [Using Nogging with herdr](using-with-herdr.md). |
| `session_tmux_command` | string | `tmux` | Executable used for the tmux backend. |
| `session_tmux_socket` | string | `nogging` | Name of the dedicated tmux socket; sessions never run on your default tmux server. |
| `session_herdr_command` | string | `herdr` | Executable used for the herdr backend. |
| `session_herdr_session` | string | `nogging` | Name of the herdr session that owns Nogging's panes. |
| `session_herdr_state_dir` | path | `.nogging/state/herdr` under the main checkout | Where the herdr backend keeps its state. Normally set by the scripts, not by you. |
| `session_repository_root` | path | the checkout root | Set by the scripts for the herdr backend. Do not set it by hand. |
| `session_repository_slug` | string | derived from the main checkout name | Set by the scripts for the herdr backend. Do not set it by hand. |
| `session_state_dir` | path | `.nogging/state/sessions` | Where session records live. |
| `session_log_max_bytes` | integer | `1048576` | Size at which a session log rotates. |
| `session_log_rotation_depth` | integer | `3` | How many rotated logs are kept. |
| `session_stop_grace_seconds` | number | `10` | How long `session stop` waits for a session to exit before it ends it. |
| `session_startup_timeout_seconds` | number | `120` | Timeout waiting for the session's initial input readiness. Accepted range 1 to 600. |
| `session_submit_delay_seconds` | number | `0.3` | Pause before the Enter that submits a sent message. Accepted range 0 to 5. |
| `session_submit_verify_delay_seconds` | number | `0.5` | Polling interval while a send verifies that the message was submitted. Accepted range above 0 to 5. |
| `session_delivery_timeout_seconds` | number | `15` | Timeout for verified message delivery. Accepted range 1 to 120. |
| `session_checks_stale_seconds` | integer | `1800` | Age after which a cached pull-request check observation counts as stale. |
| `session_launch_profile` | path | `.nogging/launch-profiles/trusted.json` | Launch profile used when `--profile` is not given. A configured value wins over the directory default. |
| `session_launch_prompt` | path | `.nogging/launch-prompts/autonomous.md` | Launch prompt used when `--prompt` is not given. A configured value wins over the directory default. |
| `session_launch_profile_dir` | path | `.nogging/launch-profiles` | Directory searched for a profile named on the command line. |
| `session_launch_prompt_dir` | path | `.nogging/launch-prompts` | Directory searched for a prompt named on the command line. |
| `orchestrator_lock_ttl_seconds` | integer | `86400` | Age after which another host's orchestrator lock counts as stale. |
| `orchestrator_poll_seconds` | number | `5` | Seconds between the supervisor's checks that the orchestrator session is still alive. |

Timing keys outside their accepted range, booleans and non-numeric values are
refused by name.

## Models

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `tier_overrides` | object | `{}` | Changes the reasoning effort of one tier and agent without touching the researched table. See [the block below](#tier_overrides). |
| `doctor_agy_models_timeout_seconds` | integer | `15` | Time limit for the `agy models` probe that `doctor` runs when Antigravity is installed. |

## Usage

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `usage_gate` | object | see [the block below](#usage_gate) | Admission control that refuses or warns on launches near a usage window. |
| `token_usage_remote` | string | `origin` | Git remote that `token-usage sync` uses. See [Token usage](token-usage.md). |
| `token_usage_drain_seconds` | number | `20` | Time budget, in seconds, for collecting session usage in one pass. |
| `token_usage_refresh_seconds` | number | `300` | Minimum seconds between bounded usage refreshes of a live session during supervision. |
| `token_usage_refresh_drain_seconds` | number | `5` | Time budget, in seconds, for one such refresh. |

## Multi-machine

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `multi_machine` | boolean | `false` | When `true`, a trusted or orchestrator session runs `bd dolt pull` before it reads Beads state and `bd dolt push` after it writes any Bead. Use it only when several machines share one Dolt remote. See [Failure recovery](failure-recovery.md) for the recovery path if two machines write before either pulls. |

## Agent state

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `agent_state_roots` | object | `{"antigravity": ["~/.gemini/antigravity-cli"]}` | Home-directory paths a session may write for each agent. See [the block below](#agent_state_roots). |

## Work sizing

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `task_sizing` | object | `{"bead_prod_lines": [400, 1000], "commit_lines": [100, 600]}` | The size one Bead and one commit should have. Planning and Lead guidance read it; `validate` only reports a NOTE. See [the block below](#task_sizing). |

## Blocks

### `usage_gate`

An optional object. Every key is optional, and the defaults are:

```json
"usage_gate": {
  "enabled": true,
  "cap_percent": 92,
  "estimate_percent": 5,
  "stale_seconds": 600,
  "on_unknown": "warn",
  "size_multipliers": {"small": 0.5, "medium": 1, "large": 2},
  "exclude_roles": ["planning", "orchestrator"]
}
```

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | `false` turns admission off. |
| `cap_percent` | number | `92` | A launch is refused when a known window is already over this percentage. |
| `estimate_percent` | number or object | `5` | Expected cost of one launch. An object sets it per agent (`claude`, `codex`, `pi`, `antigravity`) with an optional `default`. |
| `stale_seconds` | number | `600` | Age after which an observation counts as unknown. |
| `on_unknown` | string | `warn` | `warn` launches with a warning when usage is unknown; `deny` refuses with exit 75. |
| `size_multipliers` | object | `{"small": 0.5, "medium": 1, "large": 2}` | Scale for the estimate of a Bead labelled `size:<name>`. |
| `exclude_roles` | array of strings | `["planning", "orchestrator"]` | Roles that skip the gate: any of `lead`, `specialist`, `planning`, `orchestrator`, `loop`. The internal `loop` role (scheduled loop runs) is gated unless listed. |

Unknown keys and out-of-range or mistyped values refuse every launch until
they are fixed. The semantics are in
[Running work in sessions](running-work-in-sessions.md) and
[Usage limits](usage-limits.md).

### `tier_overrides`

Shape: `{"<tier>": {"<agent>": {"effort": "<level>"}}}`, with tier `routine`,
`standard` or `complex` and agent `claude` or `codex`. Only `effort` is
accepted; Antigravity carries its effort in the model name, and an override
never changes a model. A malformed block is rejected by name.

```json
"tier_overrides": {"complex": {"codex": {"effort": "medium"}}}
```

See [Model selection](model-selection.md).

### `multi_machine`

A boolean, `false` by default. It is a single switch rather than an object; the
effect is in the [Multi-machine](#multi-machine) table above.

### `sync_protected_branches`

An array of branch names, `["main", "develop"]` by default. The timer-driven
sync never commits a mirror while `HEAD` is on one of them; an explicit
`sync --now` may. An empty array protects nothing.

### `agent_state_roots`

An object whose keys are agents (`claude`, `codex`, `pi`, `antigravity`) and
whose values are arrays of absolute or `~/` paths. Each path must be an
existing directory below your home directory, never the home directory itself.
A Bead gets a grant only through the `agent-state:<agent>` label.

```json
"agent_state_roots": {"antigravity": ["~/.gemini/antigravity-cli"]}
```

See [Security model](security-model.md).

### `task_sizing`

An optional object with two optional keys, each a `[min, max]` pair of positive
integers. An absent key takes its default:

```json
"task_sizing": {"bead_prod_lines": [400, 1000], "commit_lines": [100, 600]}
```

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `bead_prod_lines` | `[min, max]` | `[400, 1000]` | Production lines (tests excluded) one task, and so one Bead, targets. The Planning Agent writes each task as a vertical slice in this range and tags it `[~N loc]`. A smaller task states its reason in the tag, e.g. `[~80 loc: security fix]`. |
| `commit_lines` | `[min, max]` | `[100, 600]` | Changed lines one commit targets. A Lead commits a Bead in several coherent steps in this range, each carrying the `[<bead-id>]` token, with tests in the same commit as the code they cover. |

`./scripts/nogg task-sizing` prints the ranges in effect and whether each one is
configured or the default. `./scripts/nogg validate` adds a NOTE for an open
task whose estimate is below the `bead_prod_lines` minimum without a reason,
and for a live change most of whose open tasks carry no estimate. A malformed
value is a WARN and keeps the default. Neither ever fails `validate`, so a
change planned before estimates existed stays valid. See
[Operating model](operating-model.md#task-sizing).
