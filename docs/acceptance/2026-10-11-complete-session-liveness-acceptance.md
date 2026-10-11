# Complete session liveness acceptance — scoped execution evidence — 2026-10-11

This unsigned report covers `complete-session-liveness`, TASK-CSL-006
(`SPEC-z12b`), the live acceptance and issue-by-issue closure checklist for
GitHub issues #37–#42. It is a scoped implementation and acceptance report;
it does not provide human acceptance sign-off or public release authorization.

## Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-10-11 |
| Host platform | Linux aarch64 (`raspberrypi`) |
| Executor | Nogging Lead (`lead@nogging.bot`) |
| Implementation baseline | `91ba73c1434aae7add4f4a438517985874334e51` (develop) |
| Package metadata | `nogg` 2.1.0; unreleased checkout, not a new published tag |
| Node / npm | v22.23.2 / 10.9.8 |
| Python / Git | 3.13.5 / 2.47.3 |
| Bash / tmux | 5.2.37 / 3.5a |
| Available Agent runtimes | Claude Code 2.1.296, Codex CLI 0.162.1, Pi 0.85.0, Antigravity 1.3.3 |
| Distribution path | `npm pack --ignore-scripts`, extract archive, run packaged `bin/cli.js` |

## Payload inventory

`npm pack --ignore-scripts --dry-run --json` reports packaged files at baseline:

| Helper | Bytes | SHA-256 |
| --- | ---: | --- |
| `scripts/nogg` | 274429 | `a01ec30c33a9ceac3fc153579976371cb1ba15ea7fa780dcf2da34e9e0486716` |
| `scripts/session-launch` | 14825 | `8afee78079fda7e29dc2cd6758018155c40c55ecfd6eda00ee94f03bee813545` |
| `scripts/session-log-writer` | 1161 | `b322fefa31be7159b3fb1eabca238ddbf6cd1f49bf49b998f9d4fb26662f49cb` |
| `scripts/openspec-sandbox` | 5638 | `9cce7cb291a9b7b5f0f4034c641589c7f78cbf89ce6f2ded1c01dc920a3b0764` |

## Live supported-runtime acceptance scenarios

All scenarios are exercised on the packaged consumer payload driving live tmux
sessions and verified in `scripts/session-liveness-acceptance.test.sh`:

### 1. First-time launch & kickoff (#37, #38, #39, #40)

| Scenario / Behavior | Result | Evidence |
| --- | --- | --- |
| Blocked Bead launch refusal (#37) | pass | Launch for a Bead with unmet dependencies (`SPEC-dep-blocked`) is refused before tmux session or record creation, naming the blocker. |
| Bare Lead launch warning (#38) | pass | Launch without `--full-access` emits `launched in restricted/manual mode` warning. |
| Bare Lead kickoff hint (#39) | pass | Launch without `--kickoff` outputs `this session will not act until you send it a first message — run nogg session kickoff <name>`. |
| Explicit kickoff execution (#39) | pass | `nogg session kickoff <name> --change <change>` submits the kickoff message to the session pane and records authorized change scope. |
| Launch with `--kickoff` (#39) | pass | Launching with `--kickoff` flag submits the kickoff turn immediately and suppresses the missing-kickoff hint. |
| Full-access disclaimer & deny preservation (#40) | pass | `--full-access` launch uses `bypassPermissions` with `skipDangerousModePermissionPrompt: true`, suppresses manual-mode warning, and preserves command floor deny rules (`sudo`, `rm -rf`, `dd`, `mkfs`, `shutdown`). |

### 2. Blocked sibling isolation (#41)

| Scenario / Behavior | Result | Evidence |
| --- | --- | --- |
| Runnable assigned task with blocked sibling | pass | When working an assigned Bead (`SPEC-csl1`), an unrelated blocked sibling in the change (`SPEC-blocked-sib`) outside its dependency cone does not classify the session as `bead-blocked`. `session sweep` reports `active`. |
| Whole-change scope blocker awareness | pass | When whole-change scope is explicitly authorized, `session sweep` identifies unresolved change blockers and reports `bead-blocked (SPEC-blocked-sib)`. |

### 3. Two consecutive ready Beads in authorized change & pause nudge (#41, #42)

| Scenario / Behavior | Result | Evidence |
| --- | --- | --- |
| Active session on first Bead | pass | `session sweep` reports `active` while the session executes its first assigned Bead in the authorized change. |
| Seamless transition to second ready Bead | pass | When the first Bead (`SPEC-csl1`) closes, the session transitions to the next ready Bead (`SPEC-csl2`); `session sweep` continues reporting `active`. |
| Pause between Beads placeholder/empty nudge (#42) | pass | Nudge without `--message` on an empty or placeholder prompt executes nothing, does not submit bare Enter, and informs operator to pass `--message`. |
| Explicit instruction nudge submission (#42) | pass | Nudge with `--message "<instruction>"` clears pending text, injects explicit instruction, and verifies submission with bounded retry. |
| Scope completion on closure and integration | pass | Once all mapped tasks are closed and local integration evidence (`commit`, `target_ref: refs/heads/develop`) is verified, `session sweep` reports `change-complete`. |

### 4. CI check transition, explicit checks-ack & doctor cache reuse (#41)

| Scenario / Behavior | Result | Evidence |
| --- | --- | --- |
| Initial passing check observation | pass | `session sweep --checks` queries PR `statusCheckRollup` and caches the head SHA and run fingerprint, reporting `checks passing ... (unchecked)`. |
| Explicit observation acknowledgement | pass | `session checks-ack <name> --fingerprint <fp>` records operator acknowledgement; subsequent `sweep --checks` reports `(acknowledged)`. |
| Transition to new failing run | pass | A new CI check run failure changes the fingerprint; `sweep --checks` reports `checks failing ... (unchecked)` with failed check name. |
| Offline doctor cache reuse | pass | `nogg doctor` reuses the cached check failure note without making remote network calls. |

## Issue-by-issue #37–#42 closure checklist

| Issue | Title | Status | Verifying commits & artifacts | Resolution summary |
| --- | --- | --- | --- | --- |
| [#37](https://github.com/JoMe92/nogging/issues/37) | Refuse to launch a Lead/specialist session for a Bead with open dependencies | **CLOSED** | PR #45, #85 (`8994bce`); `scripts/packed-session-launch.test.sh`, `scripts/session-liveness-acceptance.test.sh` | Session launch evaluates unmet dependencies before tmux creation or session recording; unmet blockers fail fast naming the blocking Bead. Orchestrator launch is unconstrained. |
| [#38](https://github.com/JoMe92/nogging/issues/38) | Lead sessions launched without --full-access hang silently in manual mode | **CLOSED** | PR #45, #85 (`8994bce`); `scripts/packed-session-launch.test.sh`, `scripts/session-liveness-acceptance.test.sh` | Shipped launch warns operator when starting in restricted/manual mode. Warning is suppressed on `--full-access` and `--role orchestrator`. |
| [#39](https://github.com/JoMe92/nogging/issues/39) | session launch never sends a first turn, with nothing surfacing kickoff step | **CLOSED** | PR #46, #85 (`8994bce`); `scripts/packed-session-launch.test.sh`, `scripts/session-liveness-acceptance.test.sh` | Bare launch prints explicit kickoff command hint; `session kickoff` delivers first turn and records change scope; `--kickoff` automates turn submission at launch. |
| [#40](https://github.com/JoMe92/nogging/issues/40) | shipped trusted.json uses acceptEdits, not bypassPermissions | **CLOSED** | PR #46, #85 (`8994bce`); `scripts/packed-session-launch.test.sh`, `scripts/session-liveness-acceptance.test.sh` | `--full-access` profile sets `defaultMode: bypassPermissions` and `skipDangerousModePermissionPrompt: true` while preserving shipped command floor deny list. |
| [#41](https://github.com/JoMe92/nogging/issues/41) | nothing detects a running session whose assigned change is complete or blocked | **CLOSED** | PR #86 (`b539bf3`), PR #87 (`e141f1c`), PR #92 (`f6210c2`); `scripts/session-sweep-scope.test.sh`, `scripts/session-sweep-checks.test.sh`, `scripts/session-liveness-acceptance.test.sh` | `session sweep` classifies sessions as `active`, `bead-blocked`, or `change-complete`. Unrelated blocked siblings do not over-block. `sweep --checks` monitors CI status with explicit `checks-ack` and offline `doctor` reuse. |
| [#42](https://github.com/JoMe92/nogging/issues/42) | sessions pause between Beads, and un-sticking one needs clear-then-resend | **CLOSED** | PR #88 (`dc2b79d`); `scripts/session-nudge-placeholder.test.sh`, `scripts/session-liveness-acceptance.test.sh` | `pane_input()` classifies framed prompts as input, empty, placeholder, or unknown. Bare nudge refuses to execute suggestions or empty boxes; explicit `--message` clears and resends with bounded verification. |

### Downstream blockers and dependencies

- All 6 tasks in `complete-session-liveness` (`TASK-CSL-001` through `TASK-CSL-006`) are implemented, verified, and closed.
- There are no remaining blockers within the `complete-session-liveness` change scope.
- Closing `SPEC-z12b` unblocks `SPEC-ggf2` (`TASK-GSU-001` in `get-session-usage`), enabling subsequent session usage tracking work.

## Validation results

| Check | Result | Evidence |
| --- | --- | --- |
| Full script test suite | pass | `env npm_config_cache=/tmp/spec-z12b-npm-cache ./scripts/test`: 66 test suites passed |
| Live session liveness acceptance | pass | `scripts/session-liveness-acceptance.test.sh`: all #37–#42 live scenarios passed |
| Git whitespace check | pass | `git diff --check`: clean |

## Sign-off

Signed-off-by:
