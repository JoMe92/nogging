# Dual runtime orchestrator compatibility retest — 2026-10-21

Unsigned **blocked** evidence for TASK-DRO-001 / SPEC-8prb against revised
planning commit `dcb8a350810f614bcacaae0ee41c0843d5fe23ef`. The earlier
`2026-10-21-orchestrator-runtime-contract.md` is historical negative evidence
and is preserved unchanged. This run checks installed interfaces, not the
future orchestrator implementation or the later three-selection acceptance.

## Prerequisites and isolation

The operator explicitly approved trust for exactly
`/tmp/dro001-axd_lk4g/consumer`. Only that project's trust entry was added.
Normal native readiness was observed without an initial prompt or bypass
flag; the process then exited before immutable post-setup hashes were taken.
Codex 0.163.0, Happier 0.2.16 and the reviewed inert Git fixture were retained.
No production service or fleet socket was used. The new private socket was
`/tmp/dro001-axd_lk4g/retest/tmux.sock`; captured runtime processes were in
`pid:[4026531836]`. No reboot or service restart is claimed.

Child environments deliberately received synthetic parent thread/session,
pending-first-input and unknown control variables before sanitation. The
sanitizer removed those variables, preserved existing account/server/home
locators and selected the appServer backend. Neither scratch transcript
contains the synthetic contamination marker. Credentials were neither copied
nor printed. Global config, global rules, repository rules and both fixture
files matched their post-setup hashes after all probes.

The latest quota was 90% primary / 15% weekly at admission and 96% / 16%
afterwards. Starts were bounded by a 240-second watchdog and rechecked
against remaining quota. Model probes used Luna; no heavier worker launched.

## Observed results

| Check | Outcome | Evidence / limitation |
| --- | --- | --- |
| Native trusted cold initialization | pass | Normal prompt accepted the unique inert probe, without trust or hook bypass flags. |
| Native authority/model/effort | pass | Actual turn context: `danger-full-access`, approval `never`, `gpt-6-luna`, `medium`. |
| Native allowed command and retained rules | pass | `printf DRO_ALLOWED_NATIVE` succeeded; actual executor rejected `printf DRO_RULE_SENTINEL` once. No workaround or retry of the denial. |
| Native backend network | pass | Independently allowed Python urllib request to `https://example.com` returned HTTP 200. An earlier quoting error returned SyntaxError; only the corrected command supports the pass. |
| Native exact resume | pass | Explicit recorded UUID resumed the same rollout and returned `DRO_NATIVE_EXACT_RESUMED`; history retained prior command results. |
| Wrapped cold initialization and first input | pass | Owned wrapper registered a new remote ID; its first user request contained the intended probe marker, without inherited synthetic input. |
| Wrapped authority/model/effort | pass on cold start | Actual turn context: `danger-full-access`, approval `never`, Luna, `medium`. |
| Wrapped allowed command, retained rules and network | pass | Allowed printf succeeded, actual sentinel execution was rejected, independent urllib request returned HTTP 200. |
| Wrapped remote round trip | pass | Completed remote history and matching native rollout contain `DRO_HAPPIER_RETEST_READY` and command results. Send receipt alone was insufficient. |
| Direct wrapped resume flags | fail | `happier codex --existing-session <remote-id> --resume <thread-id>` exited with `missing session attach secret`. No secret was extracted or supplied manually. |
| Send to inactive remote ID | unsuitable for owned launch | A subsequent send automatically resumed through the existing Happier daemon, outside private tmux ancestry. It was explicitly stopped; this is not accepted as tmux-owned recovery. |
| Supported public resume entrypoint | partial pass | `happier resume <remote-id>` internally established attachment and reopened the same native UUID beneath owned tmux. A remote request returned the original unique marker plus `DRO_HAPPIER_PUBLIC_EXACT_RESUMED` in both histories. |
| Resume configuration preservation | fail / blocker | Both daemon and public resume actual turn contexts used `low`, rather than the cold-start `medium`. Public resume also opened a local remote-connected Codex TUI alongside its app-server process. Single-agent ownership/readiness and explicit effort forwarding require a verified supported contract before dependent implementation. |
| Complete stop | pass for probe cleanup | Scoped Happier stop returned `stopped: true`; final remote state was inactive. Every captured PID/start-time identity from native, wrapped, daemon-resumed and public-resumed trees was gone. No process retained the fixture cwd; private tmux server exited. |
| Policy immutability | pass | All five post-setup file hashes remained identical; no implicit global trust mutation occurred. |
| Service recovery / Claude / mobile UI | not run | Later acceptance scope; API round trip does not prove phone UI interaction, systemd recovery or host reboot. |

## Attributable identities and tested interface

Native cold/resume thread: `01a15ff7-1068-7302-ac69-be2937725c00`.
Wrapped remote: `cmviilpqe02z5yqqt6ooa8sn6`.
Wrapped native cold/resume thread: `01a15ff9-2255-72a3-a667-8221ec23f05f`.
Attribution used the unique fixture, creation interval, owned process ancestry,
new registration and matching unique marker in remote/native histories;
it did not choose the newest shared-path session. Remote/native IDs were
kept distinct.

Native invocation retained `--no-daemon --no-alt-screen --cd <fixture>
--sandbox danger-full-access --ask-for-approval never --model gpt-6-luna
-c 'model_reasoning_effort="medium"'`; exact resume added
`resume <native-uuid> <inert-prompt>`.

Wrapped cold start retained `HAPPIER_CODEX_BACKEND_MODE=appServer` and
`happier codex --cd <fixture> --happy-starting-mode remote
--permission-mode yolo --model gpt-6-luna
-c 'model_reasoning_effort="medium"'`. The supported alternative resume
entrypoint tested was `happier resume <verified-remote-id>`; its installed
handler creates its own attachment context. No internal attach credential
was passed on a command line. No rule bypass, masked policy directory,
authentication/account change or exec-only architecture was attempted.

## Required follow-up

SPEC-8prb remains blocked and its discovery label is retained. Verify an
installed, supported tmux-owned Happier resume contract that forwards the
requested effort and has unambiguous backend/frontend ownership. Sending to
an inactive remote ID must not be used as an implicit launch or readiness
probe: it can spawn through the daemon. Recheck actual turn settings, not
just model labels or stored metadata, after resume. These findings do not
justify implementing an unverified adapter or closing dependent Beads.

Private evidence stays in `/tmp/dro001-axd_lk4g/retest/`, with the immutable
baseline and setup receipt in the sibling `retest-preparation/`. Validation
asserted post-setup hashes, actual executor rejections, exact thread replies,
remote history markers, no inherited contamination, inactive remote state
and disappearance of captured process identities. Raw logs are not published.
No OpenSpec task tick or product implementation changed.

Signed-off-by:
