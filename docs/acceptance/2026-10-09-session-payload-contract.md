# Session payload contract — scoped execution evidence — 2026-10-09

This unsigned report covers `repair-session-payload-contract`, TASK-PSC-006
(`SPEC-4yyg`). It is a targeted installer/session acceptance run, not the
complete product acceptance runbook or public-release sign-off.

## Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-10-09 |
| Host platform | Linux aarch64 |
| Executor | Nogging Lead |
| Implementation baseline | `bdf5a1ebe678b6eb6269add0e3f1c34f32d960b0` |
| Implementation commits | `5374be3`, `b6c99f4`, `6d99a00`, `fe302bd`, `bdf5a1e` |
| Package metadata | `nogg` 2.1.0; unreleased checkout repairs, not a new published tag |
| Node / npm | v22.23.2 / 10.9.8 |
| Python / Git | 3.13.5 / 2.47.3 |
| Bash / tmux | 5.2.37 / 3.5a |
| Agent/backend mode | Stub Claude, Codex, Pi and Beads; real local Git and tmux |
| Distribution path | `npm pack --ignore-scripts`, extract archive, run packaged `bin/cli.js` |

## Payload inventory

`npm pack --ignore-scripts --dry-run --json` reports 87 files. The three runtime
helpers are present in that archive and install with mode 0755:

| Helper | Bytes | SHA-256 |
| --- | ---: | --- |
| `scripts/nogg` | 177169 | `8a9107fca6994a3c0d2e4f8df0e99e90436cc076196106f651949e31ee3ff2d8` |
| `scripts/session-launch` | 9770 | `50a0920257b333fc1840f40c3ef3c53d361326fee7814c573119e6b3e4d2d2cc` |
| `scripts/session-log-writer` | 1161 | `b322fefa31be7159b3fb1eabca238ddbf6cd1f49bf49b998f9d4fb26662f49cb` |

## Validation results

| Check | Result | Evidence |
| --- | --- | --- |
| Complete source suite | pass | `scripts/test`: all script tests passed |
| Strict planning validation | pass | `openspec validate repair-session-payload-contract --strict` |
| Packed fresh installation | pass | `scripts/packed-session-launch.test.sh`: Claude, Codex and Pi launched in real tmux; runtime argv, record, log, stop and cleanup verified |
| Packed old-install update | pass | Same three runtimes after deleting the launcher and replacing the log writer with stale non-executable content; packaged helpers restored byte for byte |
| Consumer ownership | pass | `scripts/session-payload-install.test.sh`: init/update/update/remove in a path containing spaces preserves OpenSpec, Beads, custom profiles, user hooks, settings and extensions |
| Helper refusal | pass | `scripts/session.test.sh`: missing/non-executable/version-skew/unsupported-option cases refuse before any tmux call or session directory |
| Immediate startup failures | pass | Stub unknown-option and missing-exec failures preserve redacted diagnostics and failed records; `scripts/session-startup.test.sh` reproduces failure with real tmux |
| Concurrent lifecycle updates | pass | Real-tmux regression verifies a late running transition cannot resurrect a failed session |
| Installed self-tests and docs | pass | `scripts/installed-diagnostics.test.sh`: installed suite passes without optional `claim_stale_seconds`; installed relative Markdown links resolve |
| Diagnostics | pass | Missing, non-executable and stale helper interfaces are reported; a missing log writer produces a failing `doctor` verdict |
| Whitespace validation | pass | `git diff --check` |

## Scope and discoveries

Issue #43 has execution evidence for the repaired installed payload, interface
negotiation and startup diagnostics. The installer portion of #51 is covered;
model selection still requires `configure-session-models` and TASK-SCM-004.
No GitHub issue was automatically closed.

Resolved findings were recorded on the owning Beads: SPEC-4gpy (name allocation
called tmux before preflight), SPEC-5ktw (an immediate child failure can race
the launcher's running transition), and SPEC-jq8n (consumer fixture helpers and
the relocated security-policy link). These fixes stay inside the approved
task scope. No new runtime compatibility or real-agent capability is claimed
from stub-agent tests. Remote package installation, public publication and
human product acceptance were outside this run.

## Sign-off

Signed-off-by:
