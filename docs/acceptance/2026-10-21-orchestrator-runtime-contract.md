# Orchestrator runtime contract — 2026-10-21

This unsigned, **blocked** report covers TASK-DRO-001 (`SPEC-8prb`) in
`dual-runtime-orchestrator`. It verifies parts of the installed runtime
interfaces; it does not establish the planned unrestricted orchestrator
contract or authorize dependent implementation. No product implementation
or OpenSpec task checkbox was changed.

## Scope and versions

| Field | Observed value |
| --- | --- |
| Host | Delivery Raspberry Pi, Linux; host-authorized shell |
| Nogging base | `bd1cc4a`, including planning artifacts from `b1fde7c` |
| Codex | `codex-cli 0.163.0` |
| Happier | `0.2.16` |
| tmux | `3.5a` |
| Probe model / effort | `gpt-6-luna` / `medium`, verified in runtime turn context |
| Probe directory | Unique disposable Git repository under `/tmp/dro001-axd_lk4g/consumer` |
| Session substrate | Private socket `/tmp/dro001-axd_lk4g/tmux.sock`; no fleet socket |
| Process ownership | The private tmux server and launcher had PID namespace `pid:[4026531836]`; launcher user mapping was `0 0 4294967295` |
| Quota admission | Latest prelaunch snapshot: primary 25%, weekly 5%; bounded probes fit remaining headroom |

Reading `/proc/1/ns/pid` was denied. Namespace evidence comes from the
launcher and its newly created private server, not the known-buggy Nogging
tmux namespace warning. No service was enabled and no host reboot occurred.

## Results

| Contract check | Outcome | Evidence and limit |
| --- | --- | --- |
| Native cold start in a new scratch repository without persistent consent | blocked | The TUI displayed `Trust this folder?`; invocation-only `projects.<scratch>.trust_level="trusted"` did not remove the dialog. No UI consent was supplied. |
| Native initialization and own exact-ID resume | partial pass | An inert ready response and a later `DRO_NATIVE_RESUMED` response were recorded on the same exact thread. These occurred after wrapped startup had added global trust for the scratch path; they do not prove isolated unattended trust. |
| Native effective sandbox, approval, model and effort | pass for observed settings | Actual turn context recorded `danger-full-access`, `never`, Luna and `medium`. These settings did not disable execpolicy. |
| Native role-scoped floor exception | fail | A harmless scratch `printf` sentinel rule caused an actual executor policy rejection despite those settings. |
| Interactive/app-server rule-loading override | unsupported by tested CLI interface | Both `codex --ignore-rules --help` and `codex app-server --ignore-rules --help` exited 2 with `unexpected argument`. `codex exec --help` advertises that switch, but exec is a different invocation architecture and was not substituted. |
| Happier wrapper with inherited parent environment | fail | A parent pending-first-input variable seeded the parent's initial instruction into the new remote session, despite clearing parent session/thread IDs. The private wrapper was stopped; that instruction is omitted from this public report. |
| Sanitized Happier wrapper ownership and registration | pass | A wrapper beneath the private tmux pane registered its own remote ID. Its process tree contained timeout, Happier and its own Codex child, with recorded PID/start-time identities. |
| Happier remote round trip | pass | An inert message with a unique marker received the exact `DRO_HAPPIER_READY` reply in remote history and the attributable Codex rollout. Queue acceptance alone was not used as evidence. |
| Happier effective sandbox, approval, model and effort | pass for observed settings | The associated Codex turn context recorded `danger-full-access`, `never`, Luna and `medium`. |
| Backend shell network reachability | not separately probed | Successful model replies demonstrate provider connectivity, not unrestricted network access from an executed shell command. |
| Happier role-scoped floor exception | fail | The same harmless scratch sentinel was rejected by the actual Codex executor, followed by `DRO_HAPPIER_RULE_DENIED`. |
| Global trust/configuration isolation | fail, side effect restored | During the first wrapped startup, global Codex config gained a trusted-project entry for the scratch path without UI consent. Removing only that section restored the exact baseline SHA-256. |
| Native stop | pass for probe cleanup | Every owned native pane ended; final private-scope process inspection found no runtime left in the scratch cwd. No conversation was deleted. |
| Happier stop | pass for tested CLI stop | Explicit stop of each verified probe remote ID returned `stopped: true`; remote metadata became inactive. All captured owned process identities were gone. |
| Local wrapper termination alone confirms remote stop | not established | After terminating the first private wrapper, its local processes were gone while remote metadata still said active. An explicit scoped remote stop reconciled it. This is not proof that an agent survived or that metadata was fresh. |
| Exact Happier conversation resume | not run | Further starts were stopped after detecting the authority and global-trust blockers. Advertised resume flags are not acceptance evidence. |
| Service/reboot recovery | not run | Belongs to later lifecycle acceptance; no production service or host was restarted. |

## Recorded identities

These are disposable probe identifiers, not production sessions. Local
scratch evidence retains full receipts; no parent session ID, account ID,
credential, or original parent instruction is published here.

| Probe | Happier session | Codex conversation |
| --- | --- | --- |
| Native cold start and exact resume | Not applicable | `01a15f9a-7ce2-7253-9922-797bfc172032` |
| First wrapped attempt, inherited pending input | `cmvieuiih00vlyqqthme1vxr8` | `01a15f98-8245-7ae0-82f1-2a5f8d7b99b2` |
| Sanitized remote round trip | `cmviexqvl00ynyqqt5afrz2t3` | `01a15f9c-214d-7e92-86ea-06362fdf72e1` |

Remote attribution used the unique scratch cwd, creation interval, recorded
owned process tree and matching inert response in remote history and native
rollout. It did not select the newest conversation for a shared working
directory. The first attempt's unexpected parent input invalidates it as an
inert round-trip acceptance check.

## Tested invocation surfaces

The native TUI was launched inside the private tmux session, bounded by
`timeout --signal=TERM --kill-after=5 180`, using:

```text
codex --no-daemon --no-alt-screen --cd <scratch>
  --sandbox danger-full-access --ask-for-approval never
  --model gpt-6-luna -c 'model_reasoning_effort="medium"'
  <inert ready prompt>
```

The initial invocation and its retry with an explicit per-invocation
`projects."<scratch>".trust_level="trusted"` setting remained at the trust
dialog. The later trial also included
`--dangerously-bypass-hook-trust`. That trial succeeded after the wrapped
startup had already changed global trust; **the flag's independent effect
was not established**. Exact native resume supplied the recorded UUID to
`codex resume <uuid> <inert prompt>`, retaining the same session settings.

The sanitized remote-mode wrapper used the following installed interface,
bounded by a 240-second watchdog:

```text
HAPPIER_CODEX_BACKEND_MODE=appServer
happier codex --cd <scratch> --happy-starting-mode remote
  --permission-mode yolo --model gpt-6-luna
  -c 'model_reasoning_effort="medium"'
```

`happier codex --help` advertises the provider CLI options but does not
describe every Happier wrapper option. The installed parser additionally
recognizes `--happy-starting-mode`, `--permission-mode`, `--existing-session`
and `--resume`; only the used startup options and scoped send/stop operations
were exercised here. Reattaching the same remote ID with the same native
thread remains unverified.

The wrapper environment kept only the existing Happier home/server/runtime
locator variables needed for the same local account. It removed inherited
Happier session, pending-first-input, lifecycle and service-spawn variables,
plus parent Codex thread/originator variables. No account was changed and no
credential was copied or placed on a command line.

After registration, the probe used `happier session send <verified-id>
<inert-message> --wait --timeout 30 --json`. Both sends returned a local
message receipt; completed assistant replies in history and the native
rollout separately established the round trips. For stop it used
`happier session stop <verified-id> --json`, then checked remote inactive
metadata and the absence of the captured PID/start-time process identities.

## Blocking authority evidence

The scratch repository carried only this harmless test denial:

```text
prefix_rule(pattern=["printf", "DRO_RULE_SENTINEL"], decision="forbidden")
```

Both runtimes attempted exactly `printf DRO_RULE_SENTINEL`. Their recorded
tool output contained:

```text
rejected: policy forbids commands starting with `printf DRO_RULE_SENTINEL`
```

The test did not execute a destructive command or a real command-floor
entry. The observed `danger-full-access` and `never` settings are therefore
insufficient evidence for the plan's full command-floor exception. No
supported exception for the selected interactive/app-server architecture
was demonstrated. This report does not claim that every possible Codex
integration is incapable of expressing one.

## Discoveries and required planning review

All material findings are recorded with the native `discovery` label and
human-readable notes on `SPEC-8prb`, which remains **blocked**:

1. Reconcile the unrestricted role-scoped authority requirement with the
   installed interactive/app-server policy interface. A retained Codex floor
   or an exec-based lifecycle changes approved behavior/architecture and
   needs planning review; neither was implemented as a workaround.
2. Establish a supported trust-isolation contract. Wrapped startup added
   global project trust; native initialization subsequently depended on
   that state. No isolated unattended trust success is claimed.
3. Require parent-environment sanitation, including pending initial input,
   for a Happier-controlled orchestrator. Clearing only session IDs does
   not isolate the new runtime.
4. Reconcile process termination with remote inactive state. Cached remote
   active metadata alone cannot prove that a local runtime survived, and a
   local pane exit alone does not establish remote stop completion.

## Cleanup, evidence and validation

No UI trust decision was supplied. The wrapped startup nevertheless added
exactly one scratch project section to `<HOME>/.codex/config.toml`. The
section was removed only after calculating that the resulting bytes matched
the pre-probe SHA-256. Final hashes match the original global Codex config,
global Codex rules and repository Codex rules. The native-start finding was
corrected when this causality was discovered; no per-invocation-only trust
success is inferred from the later trial.

Both verified disposable Happier sessions are inactive. Their captured
owned process identities are gone. All private tmux sessions, including its
keepalive, were stopped; the private server is down and no process remains
with the scratch cwd. Pre-existing Happier sessions and provider
conversations were preserved. No fleet socket, service, planning lock or
unrelated worktree was altered by these probes.

Private raw evidence remains under `/tmp/dro001-axd_lk4g/`: terminal captures,
CLI refusal/send/stop receipts and `state.json` with attributable runtime
IDs, process identities and baseline policy hashes. That directory includes
private parent-context metadata and is intentionally not committed. Native
rollouts remain in the installed Codex session store; they were not deleted
or copied into the report.

Report validation checks the recorded native exact ID, actual tool-policy
rejections, Happier ready reply, effective settings, inactive probe remote
IDs, vanished owned process identities and restored policy hashes.
`git diff --check` and Nogging validation cover the report change. Passing
those checks is evidence of a consistent report, not successful runtime
acceptance. No full implementation test suite is warranted for this
report-only, blocked compatibility task.

Signed-off-by:
