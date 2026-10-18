# Reliable session input — delivery host acceptance — 2026-10-18

Unsigned execution evidence for TASK-RSI-009 (`SPEC-t374`), change
`reliable-session-input`, design Decisions 1 and 9. **Overall: fail to establish
live acceptance.** A supervised child launch from an isolated scratch consumer
was refused before creating a child. Remaining live cases are skipped, not
inferred from automated tests. This report does not establish Product Owner
acceptance.

## Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-10-18, Europe/Berlin |
| Host | Linux aarch64 delivery host |
| Operator | Nogging-supervised Codex session assigned `SPEC-t374`, under Orchestrator direction |
| Toolkit version | Nogging 3.0.0 |
| Git commit tested | `bd701c48242005a8a4f04729acf8cd0fdbe92246` (`origin/develop`) |
| Install path | Fresh scratch consumer installed from the current implementation checkout with `node bin/cli.js init --no-beads --no-hooks --no-systemd` |
| Tracker | Read-only local fixture for `SPEC-t374`; no scratch Dolt database or host Dolt lifecycle operations |
| Implementation branch | `docs/reliable-session-input` |
| Prerequisites | `79b9ff4` (RSI-007) and `ad8d853` (RSI-008) are ancestors of `origin/develop` |
| OpenSpec boundary | Locked throughout; no OpenSpec files were edited |

Versions were read from installed CLIs and local tools:

| Tool | Observed version |
| --- | --- |
| Nogging | 3.0.0 |
| Claude Code | 2.1.302 |
| Codex CLI | 0.163.0 |
| Antigravity (`agy`) | 1.4.2 |
| herdr | 0.9.5 |
| tmux | 3.5a |
| Python | 3.13.5 |
| Node.js | v22.23.2 |
| Git | 2.47.3 |

Codex's version command warned that it could not create PATH aliases on a
read-only filesystem; this was not a usage-limit response. No Codex runtime
conversation was launched, so runtime quota availability was not established.
A prior observed Codex 0.162.1 launch collapsed a roughly 1,000-character
kickoff paste into a `Pasted Content` placeholder. Nogging refused kickoff
because the composer did not hold the exact message; manual Enter submitted it.
That known gap was not retested on the installed 0.163.0 CLI.

## Isolation and setup

The current probe used `/tmp/nogg-rsi-t374.saPHXR`, an independent `git init`
consumer installed from the rebased implementation checkout. Its configuration
selected the private tmux socket and herdr namespace
`rsi-t374-private-saPHXR`, consumer-local session records, and 12-second startup
and 10-second delivery deadlines. The tracker fixture only answers reads for
the already-claimed `SPEC-t374`; it cannot mutate Beads. No fleet socket
`nogging`, `sf-*` session, or fleet herdr namespace was accessed.

The consumer init completed and printed the expected uninitialized-tracker
readiness warning. A restricted supervised Claude test-runner launch was then
attempted through the consumer's `./scripts/nogg session launch` command.

## Observed launch result

The launch exited **1** with:

```text
nogg: [Errno 30] Read-only file system: '/home/jome/.cache/nogging/usage/reservations'
```

It failed at the shared usage-reservation cache before a child or session record
was created. `./scripts/nogg session list` then reported `no managed sessions`.
There is no child launch log. Admission did not report a runtime usage limit.
The launch was not retried with altered authority, cache settings, a direct
agent command, or another transport.

`./scripts/nogg doctor` exited 0 in the scratch consumer, reported no recovery
items, and identified the scoped setup. It also reported that the Codex sandbox
write probe could not be built because its app-server socket directory was not
user-owned with mode 0700, and that an external Claude parent lacks the scoped
supervised-launch rules. Doctor success is diagnostic only; it does not prove a
child can launch. No backend server was created.

## Step results

| Step | Result | Evidence or reason |
| --- | --- | --- |
| Install independent scratch consumer | pass | Nogging 3.0.0 init completed; expected warning for the deliberately uninitialized tracker |
| Configure private backend namespaces | pass | Both configured as `rsi-t374-private-saPHXR`; no managed session after refusal |
| Record installed agent and transport versions | pass | Versions listed above |
| Claude / tmux supervised launch | fail | Exit 1 at read-only usage-reservation cache; no child created |
| Claude / herdr live delivery | skipped | No child was created; private herdr probe was not attempted after the cache refusal |
| Codex / tmux live delivery | skipped | No Codex child was attempted after the cache refusal; runtime quota was not established |
| Codex / herdr live delivery | skipped | No Codex child or private herdr probe; runtime quota was not established |
| Antigravity / tmux live delivery | skipped | Operator reports weekly quota exhausted until `2026-10-23T22:00Z`; no launch attempted |
| Antigravity / herdr live delivery | skipped | Operator reports weekly quota exhausted until `2026-10-23T22:00Z`; no launch attempted |
| Long and multiline kickoff/send/nudge | skipped | No running child; no message identifiers, receipts, replies or composer captures |
| Early AGY kickoff and startup beyond 30 seconds | skipped | No AGY child; the Pi timing hypothesis remains untested live |
| Delayed first turn and missing Stop-hook diagnostic | skipped | No runtime startup or hooks to observe |
| Concurrent and repeated kickoff attempts | skipped | No running child; duplicate suppression was not observed live |
| Codex queue acceptance versus fresh submitted receipt | skipped | No Codex thread, queue request or submitted-user-message receipt |
| Pending input and bounded replacement | skipped | No composer; no stale draft was typed or cleared |
| Startup/trust/permission failure and speculative-input handling | skipped | Observed failure occurred before runtime startup |
| Retry counts, deadlines and composer leftovers | skipped | No delivery attempted; configured deadlines were not exercised |
| Scoped `./scripts/nogg doctor` | pass | Exit 0; no scratch recovery items; sandbox limitation reported above |
| `scripts/test` | fail | Full suite with temporary HOME/npm cache exited 1 in `scripts/packed-session-launch.test.sh`: its runtime stub requires `NOGG_OPENSPEC_FENCED=1` during the orchestrator launch, although orchestrator launches intentionally do not use the execution fence. Delivery-specific suites passed. |
| Teardown | skipped | No child or backend server was created; scratch consumer retained as evidence |
| Product Owner sign-off | skipped | Human decision; signature intentionally blank |

## Deviations and discovery

This task-specific matrix does not run the general release acceptance procedure
or a published-distribution install. It installed locally without a real
tracker, hooks or systemd. Only one restricted Claude child launch was attempted;
Codex and Antigravity sessions were not launched. The Antigravity cases are
skipped specifically because the operator reported weekly quota exhaustion
through `2026-10-23T22:00Z`. Focused delivery suites
(`session-delivery-docs`, `session-delivery-integration`, kickoff, input-ready,
Codex receipt/queue and paste transport) passed in `scripts/test`. The full suite
was rerun with temporary writable HOME and npm-cache paths; the unrelated
packed-session-launch orchestrator-fence assertion described in the
test-results table remained the failure.

Discovery is recorded on `SPEC-t374` with the native `discovery` label: this
supervised environment cannot write the usage-reservation cache, so child
launch fails before a runtime starts. This does not block an honest report, but
it blocks live acceptance evidence. A host-capable session must repeat the
agent/backend cases in its own scratch consumer and private backend namespaces
before claiming live delivery acceptance. It must record exact message
identifiers, fresh receipts, retries, elapsed deadlines, composer leftovers and
any real Codex usage-limit response.

A separate non-blocking test discovery is recorded on `SPEC-t374`: on this host,
`scripts/packed-session-launch.test.sh` reaches its live namespace path and fails
because a shared runtime stub requires the execution-only
`NOGG_OPENSPEC_FENCED=1` marker for the orchestrator case. The orchestrator is
intentionally exempt from that execution fence. Planning review should update
the fixture to assert the fence for execution roles while preserving the
orchestrator exception; this is outside TASK-RSI-009.

## Sign-off

Signed-off-by:
