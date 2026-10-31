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
| `pi_extensions` | array of strings | `[]` | Names of the optional Nogging Pi extensions under `.pi/nogging/extensions/` that every `session launch --agent pi` loads, after the guard and in this order, for example `["glm-usage"]`. A name must be kebab-case, unique and have an `index.ts` in the launch working directory; otherwise the launch refuses before any side effect, naming the key and the value, and `validate` and `doctor` report a FAIL. The session record stores the loaded names and the launch output prints `pi-extensions=<names>`. An empty or absent list changes nothing, and other agents ignore the key. `init` scaffolds `[]` and `update` keeps your value. See [Pi extensions](pi-extensions.md) and [Using Nogging with Pi](using-with-pi.md). |
| `session_backend` | string | `tmux` | Terminal backend for launches without `--backend`: `tmux` or `herdr` (experimental). The `--backend` flag wins over this key. See [Using Nogging with herdr](using-with-herdr.md). |
| `agent_routing_file` | path | `.nogging/agent-routing.json` | Repository-relative location of the agent routing file, resolved against the main checkout so every linked worktree reads the same file. See [the block below](#agent_routing_file). |
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
| `doctor_agy_models_cache_seconds` | number | `3600` | How long `doctor` reuses a successful `agy models` listing, per `agy` executable (cached under `$XDG_CACHE_HOME/nogging/`). A failed probe is never cached; `0` probes on every run. |

## Usage

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `usage_gate` | object | see [the block below](#usage_gate) | Admission control that refuses or warns on launches near a usage window. |
| `token_usage_remote` | string | `origin` | Git remote that `token-usage sync` uses. See [Token usage](token-usage.md). |
| `token_usage_drain_seconds` | number | `20` | Time budget, in seconds, for collecting session usage in one pass. |
| `token_usage_refresh_seconds` | number | `300` | Minimum seconds between bounded usage refreshes of a live session during supervision. |
| `token_usage_refresh_drain_seconds` | number | `5` | Time budget, in seconds, for one such refresh. |
| `token_usage_query_timeout_seconds` | number | `30` | Time limit, in seconds, for each local Dolt query behind `token-usage report`, `session`, `export`, `import` and `status`. A busy or very large store then fails with a clear error instead of hanging. |

## Session wake

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `session_dispatch` | object | see [the block below](#session_dispatch) | Deterministic follow-ups for supervised sessions. On by default. |
| `orchestrator_context` | object | see [the block below](#orchestrator_context) | Context budget values for the Orchestration Agent. |

## Multi-machine

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `multi_machine` | boolean | `false` | When `true`, a trusted or orchestrator session runs `bd dolt pull` before it reads Beads state and `bd dolt push` after it writes any Bead. Use it only when several machines share one Dolt remote. See [Failure recovery](failure-recovery.md) for the recovery path if two machines write before either pulls. |

## Loops

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `loops_file` | path | `.nogging/loops.json` | Repository-relative path of the scheduled loop definitions file. Each loop's prompt lives at `loops/<name>.md` in that file's directory. Set it to `.nogging/state/loops.json` to keep loops and prompts host-local and untracked; the prompts then share `.nogging/state/loops/` with the loop runtime files. A missing file means no loops. `nogg validate` and `doctor` fail on an invalid file or prompt. See [Commands](commands.md) for the `nogg loop` commands. |

## Agent state

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `agent_state_roots` | object | `{"antigravity": ["~/.gemini/antigravity-cli"]}` | Home-directory paths a session may write for each agent. See [the block below](#agent_state_roots). |

## Work sizing

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `task_sizing` | object | `{"bead_prod_lines": [400, 1000], "commit_lines": [100, 600], "bead_test_lines": [1, 1500]}` | The size one Bead and one commit should have. Planning and Lead guidance read it; `validate` only reports a NOTE. See [the block below](#task_sizing). |

## Test control

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `testing` | object | see the block | What `nogg test` runs per stage, its budgets, the full-suite lock and the heavy slots. See [the block below](#testing). |

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
| `stale_seconds` | number | `600` | Age after which an observation counts as unknown. For Pi it also sets how long the `pi-zai.json` snapshot is used before a probe refreshes it. |
| `on_unknown` | string | `warn` | `warn` launches with a warning when usage is unknown; `deny` refuses with exit 75. Pi usage is known when a Z.ai key is configured in Pi, so this applies to Pi whenever that quota is unknown; see [Pi via Z.ai](usage-limits.md#pi-via-zai). |
| `size_multipliers` | object | `{"small": 0.5, "medium": 1, "large": 2}` | Scale for the estimate of a Bead labelled `size:<name>`. |
| `exclude_roles` | array of strings | `["planning", "orchestrator"]` | Roles that skip the gate: any of `lead`, `specialist`, `planning`, `orchestrator`, `loop`. The internal `loop` role (scheduled loop runs) is gated unless listed. |

Unknown keys and out-of-range or mistyped values refuse every launch until
they are fixed. The semantics are in
[Running work in sessions](running-work-in-sessions.md) and
[Usage limits](usage-limits.md).

### `session_dispatch`

An optional object. Every key is optional, and the template carries the block below.
[Session wake](session-wake.md) explains what dispatch does and what it costs.

```json
"session_dispatch": {
  "enabled": true,
  "max_nudges": 2,
  "max_ci_nudges": 2,
  "stall_after": "15m",
  "ci_timeout": "60m",
  "retire_merged": false,
  "wake": {
    "urgent_quiet": "90s", "normal_quiet": "300s", "max_hold": "900s",
    "min_gap": "300s", "max_wakes_per_hour": 4, "remind_after": "4h",
    "hold_above_percent": 85,
    "keep_warm": true, "keep_warm_after": "50m", "quiet_hours": []
  },
  "precompact_after": "50m",
  "precompact_min_tokens": 100000
}
```

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `enabled` | boolean | `true` | Only an explicit `false` switches dispatch off: `session dispatch` then prints that it is disabled and no session is nudged, retired or woken. A missing key or block reads as on. |
| `max_nudges` | integer | `2` | Nudges per head SHA for an idle Lead with gaps or no pull request. New commits restore them. Past the budget the condition is queued as `stuck`. |
| `max_ci_nudges` | integer | `2` | Nudges for red CI, counted across fixes until CI is green. Past the budget the condition is queued as `ci_stuck`. |
| `stall_after` | duration | `15m` | Log silence of a `working` session before the stall ladder starts. A second period queues `stalled`. |
| `ci_timeout` | duration | `60m` | How long checks may stay pending before `ci_timeout` is queued. |
| `retire_merged` | boolean | `false` | Stop and clean up a session whose pull request is merged, whose Bead is closed and whose tree is clean. |
| `wake` | object | see the table below | Digest timing, keep-warm and quiet hours. |
| `precompact_after` | duration | `50m` | Idle time before the one compaction ahead of a lapsing cache. It must stay under the one-hour cache lifetime, or nothing is ever sent. |
| `precompact_min_tokens` | integer | `100000` | Smallest context worth that compaction. |

The digest and the orchestrator's keep-warm read these `wake` keys.

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `urgent_quiet` | duration | `90s` | How long `blocked`, `needs_input`, `crashed` and `stuck` wait, so that a Lead that recovers by itself wakes nobody. |
| `normal_quiet` | duration | `300s` | Calm before the other items go out, so that several landing together make one wake. |
| `max_hold` | duration | `900s` | Longest that calm may delay the oldest item, so that a steady stream cannot starve delivery. |
| `min_gap` | duration | `300s` | Least time between wakes. Urgent items ignore it. |
| `max_wakes_per_hour` | integer | `4` | Ceiling on wakes per hour. Urgent items may exceed it. |
| `remind_after` | duration | `4h` | When an item nobody acted on is repeated, once. A new head makes it a new item. It also ends the wait of an item that only unreadable evidence keeps. |
| `hold_above_percent` | number | `85` | Non-urgent items and the keep-warm wait while a known usage window of the orchestrator's agent is above this. Unknown usage holds nothing. |
| `keep_warm` | boolean | `true` | While work is active, send a Claude orchestrator one fixed line before its cache lapses. It is no wake, so `min_gap` and `max_wakes_per_hour` do not count it. `false` sends none and leaves the compaction alone. |
| `keep_warm_after` | duration | `50m` | How long the orchestrator has been idle before that line. Any turn restarts it. It must stay under the one-hour cache lifetime, or nothing is ever sent. |
| `quiet_hours` | array of strings | `[]` | Local-time windows in which the orchestrator is never woken: no digest, urgent included, and no keep-warm. Items wait, and the first pass after the window delivers what still holds as one digest. Nudges to Leads, retirement and CI tracking go on. |

A duration is a whole number with an optional `s`, `m` or `h`. A `quiet_hours` window
is `"HH:MM-HH:MM"` in the host's time zone, read from the wall clock on every pass. It
may cross midnight, as `"22:00-07:00"` does, its end is outside it, and its two ends
must differ. An unknown key or a bad value fails `validate` and `doctor`, naming it, and
`session dispatch` refuses to run.

With nothing active, in quiet hours or during a pause, no keep-warm goes out. Instead
the orchestrator gets one `/compact` per idle period, once it has been idle for
`precompact_after` with its cache still warm and its last recorded context above
`precompact_min_tokens`. A context size that cannot be read skips it, and the cache then
lapses. `doctor` prints a NOTE with these settings and the next compaction.

A pause is a command and no key: [`nogg pause`](commands.md#pause) holds an enabled
dispatcher for a few days and ends by itself, which a forgotten config edit would not.
Its state, `.nogging/state/pause.json`, is host-local and never committed.

### `orchestrator_context`

An optional object, with unknown keys refused the same way:

```json
"orchestrator_context": {"auto_compact_window": 200000, "idle_compact_min_tokens": 100000}
```

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `auto_compact_window` | integer | `200000` | The Orchestration Agent's automatic compaction window, in tokens. |
| `idle_compact_min_tokens` | integer | `100000` | Smallest context worth compacting while it idles. |

`orchestrator run` writes them into the session's effective settings `env`, as
`CLAUDE_CODE_AUTO_COMPACT_WINDOW` and `CLAUDE_CODE_IDLE_COMPACT_MIN_TOKENS`. A running
orchestrator picks up a new value at its next `orchestrator restart`.

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

An optional object with three optional keys, each a `[min, max]` pair of positive
integers. An absent key takes its default:

```json
"task_sizing": {"bead_prod_lines": [400, 1000], "commit_lines": [100, 600],
                "bead_test_lines": [1, 1500]}
```

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `bead_prod_lines` | `[min, max]` | `[400, 1000]` | Production lines (tests excluded) one task, and so one Bead, targets. The Planning Agent writes each task as a vertical slice in this range, splits one above the maximum, and tags it `[~N loc]`. A task outside the range states its reason in the tag, e.g. `[~80 loc: security fix]`. |
| `commit_lines` | `[min, max]` | `[100, 600]` | Changed lines one commit targets. A Lead commits a Bead in several coherent steps in this range, each carrying the `[<bead-id>]` token, with tests in the same commit as the code they cover. |
| `bead_test_lines` | `[min, max]` | `[1, 1500]` | Test lines (added plus deleted, in test files) one Bead should carry. The minimum makes a Bead with production code and no test line visible; the maximum flags a Bead that over-tests. Advisory, like the other keys. See the [testing policy](testing-policy.md). |

`./scripts/nogg task-sizing` prints the ranges in effect and whether each one is
configured or the default. `./scripts/nogg validate` adds a NOTE for an open
task whose estimate is below the `bead_prod_lines` minimum or above its maximum
without a reason, and for a live change most of whose open tasks carry no
estimate. It also adds a NOTE for an open task whose `Tests:` field is missing or names no
size, and for a task that already has a Bead and whose `Check:` demands the full
suite; `validate` and `materialize` refuse that `Check:` on a task with no Bead yet. A malformed value is a WARN and keeps the default. Neither ever fails
`validate`, so a change planned before estimates existed stays valid. See
[Operating model](operating-model.md#task-sizing).

The default range sits on the measured sweet spot. Across 208 Beads of one
consumer project (Codex, Claude and Pi transcripts, October 2026), the median
tokens per production line by Bead size were:

| Production lines per Bead | Median tokens per production line |
| --- | --- |
| 50–200 | 70 k |
| 200–500 | 20 k |
| 500–1000 | 9.5 k |
| 1000–2000 | 16.6 k |
| above 2000 | 18 k |

Beads of 500–1000 production lines cost the fewest tokens per line. Smaller
Beads pay the fixed cost of reading the task, the code and the rules again for
little output; far larger ones grow the context and the cached re-reads of
every turn. Raising the maximum well above 1000 therefore costs more tokens per
line, not fewer. `./scripts/nogg token-usage report --group-by bead` shows the
figure for your own Beads (see [Token usage](token-usage.md)).
### `testing`

An optional object. Every key is optional, an absent key takes its default, and
`update` never edits it. These are the defaults, with `stages` empty:

```json
"testing": {
  "stages": {},
  "budgets": {"changed": 300, "commit": 600, "bead": 1800, "full": 7200},
  "max_parallel_heavy": 2,
  "heavy_stages": ["bead", "full"],
  "slot_wait_seconds": 3600,
  "full_lock": "auto",
  "integrity": "report",
  "trend_threshold_percent": 30,
  "ci": {"branch": "develop", "job_pattern": "test", "max_age_days": 7, "cache_seconds": 21600},
  "nightly": {"enabled": true, "setup": []}
}
```

| Key | Type | Default | Effect |
| --- | --- | --- | --- |
| `stages` | object | `{}` | `changed`, `commit`, `bead` and `full`, each a command string or a list run in order that stops at the first failure. A stage with no entry uses its fallback. |
| `budgets` | object | as above | Seconds per stage. A run above its budget is reported and keeps its exit code. |
| `max_parallel_heavy` | integer | `2` | Heavy runs at once on this host, for this user. |
| `heavy_stages` | list | `["bead", "full"]` | The stages that take a slot. |
| `slot_wait_seconds` | integer | `3600` | How long a heavy run waits for a slot before it exits 75. |
| `full_lock` | string | `auto` | `auto` locks `nogg test full` where a CI configuration file exists or a nightly run is in use; `always` locks; `never` does not. |
| `integrity` | string | `report` | `enforce` makes a test-integrity finding fail the stage. |
| `trend_threshold_percent` | number | `30` | The week-over-week growth `doctor` reports. |
| `ci` | object | as above | The integration branch, the job-name pattern that counts as a test job, how old a run may be, and how long a CI check is cached. `ci.branch` also sets the base of the `bead` stage. |
| `nightly` | object | as above | Whether the nightly run may run, and the commands it runs first. |

A command never goes through a shell: it is split into arguments, and it passes
the deny rules of `run-quiet`. Four placeholders expand: `{files}` and
`{test_files}` as a whole word, into one `./`-prefixed argument per path, and
`{junit}` and `{timings}` into fresh result paths, also inside a word such as
`--junitxml={junit}`. A malformed value is a `doctor` WARN naming the key, and
that key keeps its default; an unknown key is a WARN too. Neither ever fails a
command. See [Test control](test-control.md).

`doctor` reads `ci` to check that CI really runs tests: it looks, through `gh`, for
a job on `ci.branch` or a pull request whose name matches `ci.job_pattern` within
`ci.max_age_days`, caches the answer for `ci.cache_seconds`, and prints a WARN when CI
is configured and no test job is found. It prints nothing when `gh` cannot be
reached, and it never changes the exit code. See
[Does CI really run tests?](test-control.md#does-ci-really-run-tests).

### `agent_routing_file`

A repository-relative path, `.nogging/agent-routing.json` by default. It is
the location of the **agent routing file**, the one versioned, user-owned file
that defines which agent each role launches when you pass no `--agent`. The
path is resolved against the repository's main checkout, so every linked
worktree reads the same file; put it under `.nogging/state/` to keep a
host-local order out of the repository.

The file carries `schema_version: 1` and a `roles` object whose keys are
`lead`, `specialist` and `planning`, each an ordered list of entries:

```json
{
  "schema_version": 1,
  "roles": {
    "lead": [
      {"agent": "pi", "backend": "herdr"},
      {"agent": "codex", "backend": "herdr", "on_unknown": "deny",
       "models": {"complex": {"model": "gpt-6-luna", "effort": "medium"}},
       "allow": [{"model": "gpt-6-luna"},
                 {"model": "gpt-6.1-sol", "efforts": ["low"],
                  "note": "extremely hard tasks only"}]},
      {"agent": "claude", "backend": "herdr"}
    ],
    "planning": [{"agent": "claude"}]
  }
}
```

An entry has a required `agent` (`claude`, `codex`, `pi` or `antigravity`;
`agy` is an alias) and may have `backend` (`tmux` or `herdr`), `tiers` (a
non-empty subset of `routine`, `standard`, `complex`), `models` (keyed by
tier, each `{model, effort}`, with `effort` allowed only for `claude` and
`codex`), `allow` (a non-empty list of `{model, efforts, note}`), `on_unknown`
(`warn` or `deny`) and `note` (one line of at most 200 characters). Every
`models` selection must satisfy the entry's own `allow` list. An
`orchestrator` role, an empty list, two entries of one role with the same
agent and written backend, an unknown key at any level and a duplicate JSON
key are refused naming the file, the JSON path and the rule. A missing file
means no routing: the installer never writes the file and `update` never
changes it, and nothing Nogging ships contains a routing preference.

Check the file with `./scripts/nogg route check`; `validate` and `doctor`
report an invalid file as a FAIL, and `doctor` NOTEs entries that cannot run
on this host. Launch-time behaviour is in
[Running work in sessions](running-work-in-sessions.md).
