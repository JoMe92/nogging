# Nogging acceptance report — 2026-10-16 — raspberrypi (herdr hardening)

Unsigned execution evidence for TASK-HHB-012 (`SPEC-dcuq`) of the change
`harden-herdr-session-backend`. This is the real Pi re-acceptance of the herdr
backend after the hardening tasks TASK-HHB-001 to TASK-HHB-011 landed in
`develop`. It repeats every check of the previous run,
`docs/acceptance/2026-10-16-herdr-backend.md`:

- the failed checks 12, 13, 15, 18, 22, 32, 34 and 35;
- the passed checks, as regression checks.

It then adds the checks of design Decision 13: D6, the orchestrator lock,
D10, D8 and both D9 topologies. One `--backend herdr` Lead session runs each
for Claude, Codex and Antigravity, each including exact resume. A tmux Lead
runs in parallel as a regression check. Each discovery D1–D10 of the previous
run is re-checked below as fixed or not fixed. The report follows
`docs/acceptance-report-template.md`. The step table lists the task's checks
instead of the 18 general runbook steps (see Deviations).

The `Signed-off-by:` line is left blank. Only the Product Owner signs.

## Run metadata

| Field | Value |
| --- | --- |
| Date started | 2026-10-16 (06:13–06:37 UTC) |
| Host | `raspberrypi` (Linux aarch64, kernel 6.18.50+rpt-rpi-2712) |
| Operator | Nogging Lead session `sf-lead-spec-dcuq-20261016t061225-a52d` (Claude Code, Opus 5.5), on behalf of the Product Owner. This Lead runs inside the openspec-sandbox PID namespace (`NOGG_OPENSPEC_FENCED=1`, `pid:[4026532675]`); the host namespace is `pid:[4026531836]`. |
| Toolkit version | package `nogg` 2.2.0 (`.nogging/config.json` has no `nogging_version` key) |
| Git commit | `c3c2231` (develop = origin/develop, with TASK-HHB-001 to TASK-HHB-011 integrated; implementation worktree `/home/jome/src/nogging-spec-dcuq`) |
| Runbook revision | `c8e2f6a` (`docs/acceptance.md`; not followed, see Deviations) |
| Install path exercised | none; live run of `./scripts/nogg` from the implementation worktree checkout |
| Backend | real `bd` 1.2.2 + `dolt` 2.3.1 |
| herdr | 0.9.5 at `~/.local/bin/herdr` (client protocol 22, `endpoint_protocol_generation` 1) |
| Agent runtimes | Claude Code 2.1.301, Codex CLI 0.162.1, Antigravity (`agy`) 1.4.0 |
| Other tools | tmux 3.5a, Python 3.13.5, Node v22.23.2, Git 2.47.3 |

## Setup

- **Throwaway Beads.** These Beads carried no real work. Each was claimed as
  soon as it was created, so no dispatcher could pick it up, and all were
  closed at the end:
  - `SPEC-doxi` for Claude (herdr, plus the tmux cross-check in step 43);
  - `SPEC-stri` for Codex;
  - `SPEC-xwnk` for Antigravity;
  - `SPEC-17f0` for the tmux regression Lead;
  - `SPEC-9nqv` for the foreign-checkout session of step 34.
- **Least authority and low cost.** Every session ran with `--role lead
  --profile restricted --prompt no-autonomous-claim --tier routine` and
  `--cwd /home/jome/src/nogging-spec-dcuq`. The models were
  `claude-sonnet-5-5` (effort low), `gpt-6-luna` (effort low) and
  `gemini-3.8-flash-low`. Every probe was a short echo prompt
  (`HHB-<AGENT>-<STEP>`) that used no tools. Codex stayed at 21% of its
  5-hour window before and after the run.
- **Host-side steps.** This Lead is fenced, so every host-side step ran
  through `tmux -L nogging run-shell '…'`. Each one is listed under
  Deviations as an operator action.
- **Representative commands.** Each was run from the worktree checkout:

```bash
./scripts/nogg session launch --backend herdr --role lead --bead SPEC-doxi --agent claude \
  --profile restricted --prompt no-autonomous-claim --tier routine --cwd /home/jome/src/nogging-spec-dcuq
tmux -L nogging run-shell 'cd /home/jome/src/nogging-spec-dcuq && ./scripts/nogg session herdr-server start'   # operator action
./scripts/nogg session send --verify <name> "Acceptance probe: reply with exactly the single word HHB-CLAUDE-SEND ..."
./scripts/nogg session nudge <name>
./scripts/nogg session nudge <name> --message "Acceptance probe: reply with exactly ... HHB-CLAUDE-NUDGE-MSG ..."
./scripts/nogg session list
./scripts/nogg session attach <name> --read-only
./scripts/nogg session stop <name> --reason "..."
herdr --session nogging server stop          # simulated restart, Nogging-owned server only
./scripts/nogg session reap
./scripts/nogg session cleanup [<name>]
./scripts/nogg session launch ... --resume 52692eff-266f-410c-a565-a65cb5dc6c5d   # Claude
./scripts/nogg session launch ... --resume 01a1435c-be3a-7260-a707-7ef1eb5a435b   # Codex
./scripts/nogg session launch ... --resume a430a912-6beb-49a6-8475-da82e199b554   # Antigravity
./scripts/nogg recover
./scripts/nogg doctor
```

## Step results

Each Result is `pass`, `fail` or `skipped`. Rows 1–35 keep the numbering of
the previous report. Rows 36–43 are the checks this run adds. D1–D10 are the
previous run's discoveries; N1–N4 are this run's (see below).

| # | Tag | Step | Result | Note |
| --- | --- | --- | --- | --- |
| 1 | [M] | doctor before any herdr record | pass | No herdr line; exit 0. |
| 2 | [A] | Dedicated server start | pass | The topology changed by design. The fenced Lead's launch is refused (step 40), and the server was started host-side with `session herdr-server start` (operator action, step 41). Its config holds exactly `resume_agents_on_restore = false`, `version_check = false`, `manifest_check = false` and `pane_history = false`. The server environment holds only `HERDR_CONFIG_PATH HOME LANG LOGNAME PATH SHELL TERM USER XDG_RUNTIME_DIR`. The socket has mode `0600`, and its path is 52 bytes long. The legacy receipt `{pid, start}` was upgraded in place to `{pid, start, pid_ns, socket: {dev, ino, ctime_ns}}`. The server's parent is the user's `systemd --user` (PID 810), so it does not depend on its starter. |
| 3 | [A] | Claude herdr launch | pass | Labelled pane `w1:pC`, with this process chain (host view): `session-pty-recorder` → `session-log-writer` → startup wrapper → `session-launch` → `openspec-sandbox` → `unshare` → `claude`. `HERDR_AGENT=claude` is set; `CLAUDECODE` and `TMUX` are absent. `backend_ref` holds `terminal_id`, `session_pid` and `session_pid_ns = pid:[4026531836]` (taken from the receipt). `session_pid_start` is `null`, because the launcher ran in the sandbox namespace. |
| 4 | [A] | Codex herdr launch | pass | Labelled pane `w1:pD`. The startup turn answered `I'll wait for the operator's direction before acting on any Bead` and claimed nothing. `codex_thread_id` was resolved at the first send, not at launch. |
| 5 | [A] | Antigravity herdr launch | pass | Labelled pane `w1:pE`. `antigravity_conversation_id` `a430a912-…` was recorded at launch, and herdr detects agent `agy`. |
| 6 | [A] | Claude `send --verify` | pass | `sent`; the reply `HHB-CLAUDE-SEND` appears in the pane. |
| 7 | [A] | Claude `nudge` without `--message` (placeholder) | pass | On an empty prompt: `nothing to nudge (the prompt is empty)`. Later, on a dim suggestion: `nothing to nudge (the prompt shows only a suggested placeholder, not input)`. Nothing was submitted either time. |
| 8 | [A] | Claude `nudge` without `--message` (real pending input) | pass | Single-line input typed with `herdr pane send-text` as operator setup was resent, and Claude answered `HHB-CLAUDE-NUDGE-RESEND`. A first attempt with input wrapped onto two rows was declined with `the pending input cannot be resent safely` and submitted nothing. That is the documented single-line rule, not a defect. |
| 9 | [A] | Claude `nudge --message` | pass | On a clean prompt (a fresh exact resume on a restarted server): `nudged`, exactly the sent text was submitted, and Claude answered `HHB-CLAUDE-NUDGE-MSG-CLEAN`. With wrapped pending input, the stale text is not fully cleared (step 43, N2). |
| 10 | [A] | Codex `send` | pass | Delivered through `codex queue`; answer `HHB-CODEX-SEND`. |
| 11 | [A] | Codex `nudge` without `--message` | pass | `nothing to nudge (the prompt shows only a suggested placeholder, not input)`. The new Codex composer classifier now identifies the dim `› Ask Codex to do anything` placeholder; the previous run could not identify the input at all. |
| 12 | [A] | Codex `nudge --message` | pass | D4 fixed: `nudged … (codex queue)`, answer `HHB-CODEX-NUDGE-MSG`, and nothing was left in the composer. The pane fallback (thread unresolved or queue refused) was not exercised live; `scripts/session-nudge-agents.test.sh` covers it. |
| 13 | [A] | Antigravity `send --verify` | pass | D5 fixed: `sent`, exit 0, answer `HHB-AGY-SEND`. |
| 14 | [A] | Antigravity `nudge` without `--message` | pass | `nothing to nudge (the prompt is empty)`. The composer between the rule lines is read as empty although the status bar is present. Nothing was submitted. |
| 15 | [A] | Antigravity `nudge --message` | pass | D5 fixed: `nudged`, exit 0, answer `HHB-AGY-NUDGE-MSG`. No extra Enter was sent: the pane shows exactly one exchange per probe. |
| 16 | [A] | `attach --read-only` on herdr | pass | Refused with `herdr has no read-only client; use session log --follow` (exit 1). |
| 17 | [A] | `AGENT_STATUS` | pass | Observed `idle` (Claude at launch and the resumed sessions), `working` (sampled during a Claude turn: `done → working ×3 → done`) and `done`. Shows `-` for tmux and terminal records. `blocked` and `unknown` were not observed: no trust dialog appeared, and with D2 fixed a stopped server now turns the records `failed` (status `-`) instead of `unknown`. |
| 18 | [A] | `session log` | pass | D3 fixed on both backends. The logs grew live while the sessions ran: Claude 8,563 → 17,288 B between turns, Codex on herdr 105,142 → 370,671 B, Codex on tmux 53,515 → 66,719 B. They did not grow while idle (30 s sample). The content is raw terminal bytes without LF and contains the probe answers. `session-log-writer --contract` reports `{"version": 1, "positional": 3, "features": ["byte-stream"]}`. No log reached `session_log_max_bytes` (the largest was 517,483 B), so live rotation was not exercised. `scripts/session-log-writer.test.sh` covers the bound, the depth and the archiving of every generation. Cleanup archived each log as `.log.archived-<ts>`. |
| 19 | [M] | doctor with herdr records | pass | Exit 0, with four NOTE lines: the restart note, `herdr records exist (3 non-retired); session_backend is tmux`, `herdr server (nogging): reachable (running)` and `legacy root pane w1:p1 found in herdr workspace; not closed automatically`. That last pane is the previous run's D8 leftover, which herdr restored from its snapshot. |
| 20 | [A] | stop on herdr | pass | Claude was stopped host-side, Codex and Antigravity from the sandbox (see step 42). Each time the pane closed, the record went to `stopped`, and `AGENT_STATUS` became `-`. For Claude, a host check showed that all six processes of the tree (recorder, writer, wrapper, sandbox, `unshare`, agent) were gone; for Codex and Antigravity, the root PIDs were gone. |
| 21 | [A] | Server stop (simulated restart, part 1) | pass | Before `herdr --session nogging server stop`, the receipt's PID, start time, `pid_ns` and socket identity were checked host-side against the running server. The stop ended all three herdr agents and the server (host check); the tmux Lead kept running. With D2 fixed, `session list` showed the three records as `failed` at once, no longer `running (unknown)`. |
| 22 | [A] | Recovery while the server is down | pass | D2 fixed: a same-Bead exact resume on `SPEC-doxi` was no longer refused as `a live lead session already covers`. From the sandbox it was refused by the D9 fence instead: `herdr server is down; start it from an unsandboxed shell with scripts/nogg session herdr-server start, or launch from that shell` (exit 1, no record written). `session reap` reaped the three records while the server was still down. Step 23 is the documented host-side recovery. |
| 23 | [A] | Server restart (part 2) | pass | Operator action: `session herdr-server start` host-side. The new server got PID 1255932 and a new socket inode (805594, previously 805603), and the receipt was rewritten with the host `pid_ns`. herdr restored panes `w1:pG/pH/pJ` with the same pane IDs and labels but new `terminal_id`s. They came back as plain shells, and herdr reported no agent in them. |
| 24 | [A] | list after restart | pass | The three records stayed `failed`, because their recorded `terminal_id`s no longer match. Each restored pane was listed as `NOTE: orphan herdr pane … run session cleanup (never adopted)`. |
| 25 | [A] | reap after restart | pass | `no vanished active sessions to reap`: the records were already reaped while the server was down (step 22). |
| 26 | [A] | cleanup after restart | pass | Retired 6 records. The three restored panes were closed through their own failed records; no separate orphan-close line was printed. The herdr server kept running, and every tmux session (two orchestrators, this Lead, the tmux regression Lead) stayed. |
| 27 | [A] | Last herdr record retired | pass | The herdr server kept running. No pane and no workspace was left, because a workspace disappears with its last pane. So no unlabelled pane survives; in the previous run, `w1:p1` stayed. doctor then printed no herdr line. |
| 28 | [A] | Claude exact resume after stop | pass | Same `claude_session_id` `52692eff-…`. Claude recalled `HHB-CLAUDE-SEND, HHB-CLAUDE-NUDGE-MSG, HHB-CLAUDE-NUDGE-RESEND, HHB-CLAUDE-WORKING`. |
| 29 | [A] | Claude exact resume after restart and cleanup | pass | Same ID; recalled the same four words. The launch created a fresh workspace (step 39). |
| 30 | [A] | Antigravity exact resume after stop | pass | Same conversation `a430a912-…`; recalled `HHB-AGY-SEND, HHB-AGY-NUDGE-MSG`. |
| 31 | [A] | Antigravity exact resume after restart and cleanup | pass | Recalled `HHB-AGY-SEND, HHB-AGY-NUDGE-MSG`. `send --verify` during the resumed startup succeeded on the first try. |
| 32 | [A] | Codex exact resume | pass | D7 fixed, both after stop and after restart and cleanup. `--resume 01a1435c-…` started this argv (host view): `codex resume 01a1435c-… --cd … --add-dir … --sandbox workspace-write --ask-for-approval on-request -c sandbox_workspace_write.writable_roots=[…] -c sandbox_workspace_write.network_access=false --model gpt-6-luna -c model_reasoning_effort="low"`. The launch prompt was not re-sent. The record carried `codex_thread_id` `01a1435c-…` from the start, and send went through `codex queue`. Both times Codex recalled `HHB-CODEX-SEND, HHB-CODEX-NUDGE-MSG`. |
| 33 | [A] | Parallel tmux Lead regression (Codex) | pass | Ran through the whole herdr run on `tmux -L nogging`. The mixed list showed `BACKEND tmux` and `AGENT_STATUS -`. Send through `codex queue` was answered (`TMUX-CODEX-SEND`). A nudge without a message identified the placeholder and submitted nothing. `nudge --message` through `codex queue` was answered (`TMUX-CODEX-NUDGE-MSG`), so D4 is fixed on tmux too. The log grew live (D3). The session was unaffected by the herdr stop and restart, and it stopped cleanly. |
| 34 | [A] | Cross-checkout isolation of herdr cleanup | pass | D1 fixed, now shown live. A herdr Antigravity session (`SPEC-9nqv`) launched from the main checkout shared workspace `w1`. In the worktree, `session list` printed `NOTE: 1 foreign herdr pane(s) left untouched`, and `session cleanup` left `w1:pF` running. The main checkout in turn saw the worktree's three panes as foreign. The foreign session was then stopped and retired by name in the main checkout. The NOTE wording differs from the documentation (N3). |
| 35 | [A] | Server started from a sandboxed Lead | pass | D9 fixed. The fenced launch is refused (step 40), `session herdr-server start` refuses inside the sandbox, and the host-started server's receipt carries the host namespace (step 41). |
| 36 | [A] | D6: cleanup keeps a shared tmux server that hosts sessions | pass | Shown by code and test only; by operator instruction it was not triggered live. In the code, `session_cleanup()` calls `idle_shutdown()` only when `TmuxBackend.empty()` holds: `list-sessions` must succeed and list nothing, and a failed listing counts as not empty. `TmuxBackend.idle_shutdown()` is the only `kill-server` call site. `scripts/session-cleanup-shared-tmux.test.sh` passed: with a foreign orchestrator session and all local records retired, no `kill-server` is issued. Live, cleanup ran in the worktree four times while orchestrator sessions ran, and the server survived. The worktree always kept a non-retired record, though, so that was not the D6 condition. |
| 37 | [A] | Orchestrator lock: older than the TTL, live holder | pass | The lock (pid 926) is a legacy lock without `pid_start`, aged 232,753 s against a TTL of 86,400 s. From the sandbox, in the main checkout: `orchestrator.lock: held (unverifiable), … pid 926 unverifiable (fenced caller)`, with no attention item and recover exit 0. Host-side (operator action): `held (verified), … pid 926 alive` through the legacy row (command line `python3 …/scripts/nogg orchestrator run`), recover exit 0. From the implementation worktree, recover shows no lock at all (N4). |
| 38 | [A] | D10: `task-done` from an implementation worktree | skipped | It cannot run before this commit. `task-done` refuses an open Bead, and the operator ordered commit → push → PR → `bd close` → `task-done`. Pre-check without side effects: from the worktree, `./scripts/nogg task-done SPEC-doxi` (an open throwaway Bead) went through this session's broker. The broker accepted the worktree as a registered checkout and refused only with `SPEC-doxi is not closed`. This session's broker advertises `checkout-task-broker`, and `scripts/task-done-broker.test.sh` passed. The live tick of TASK-HHB-012 is recorded on `SPEC-dcuq` and in the PR after the close. See also N1. |
| 39 | [A] | D8: no root pane | pass | Twice, after the workspace had vanished, the next launch created a fresh workspace: `w2` on the restarted server, and `w1` on the server started for step 9. Only the labelled session pane remained (`w2:p2`, `w1:p2`). The root pane was closed after `layout.apply`, and `workspace.json` was removed. doctor reported the previous run's legacy root pane `w1:p1` (step 19) and did not close it, as specified. The operator closed it (see Deviations). |
| 40 | [A] | D9: a fenced first launch with the server down | pass | Refused with `herdr server is down; …` (exit 1). This happened before any record, workspace, pane or receipt change: the state-directory listing was identical, and no new file appeared. |
| 41 | [A] | D9: host-side start and namespace check | pass | Inside the sandbox, `session herdr-server start` refused with `herdr server start is host-only; run it from an unsandboxed shell` (exit 1). Host-side (operator action): `herdr server (nogging): running (owned)`, exit 0. The receipt's `pid_ns` `pid:[4026531836]` equals the host's `/proc/self/ns/pid` and the server's `/proc/<pid>/ns/pid`; the sandbox is `pid:[4026532675]`. The receipt's socket identity equals `lstat` of the socket. A second host-side start while the server ran was idempotent: the receipt was unchanged, and no record was written. |
| 42 | [A] | D9: sandboxed Lead's sessions alive, stoppable and listable from both sides | pass | The sessions launched from the sandbox were listed identically from the sandbox and host-side (operator action), all `running` and with `AGENT_STATUS`. Claude was stopped host-side, Codex and Antigravity from the sandbox, and both sides then showed `stopped`. Exact resumes from the sandbox worked against the host-started server. |
| 43 | [A] | `nudge --message` with wrapped pending input (new) | fail | N2, on both backends. Claude's two-row wrapped pending input, typed as operator setup, is only partly cleared by the `ctrl+u` that the nudge sends: the first row stays, and the new message is appended to it. On herdr the merged text was submitted and reported `nudged`, exit 0. On tmux the merged text was left pending, and the nudge failed with `message still unsubmitted after a retry`, exit 1. |

## Re-check of the previous discoveries

| ID | Previous finding | Now | Evidence |
| --- | --- | --- | --- |
| D1 | Cleanup in one checkout closes another checkout's live herdr panes | fixed | Live, step 34; `scripts/session-herdr-ownership.test.sh` passed. |
| D2 | No recovery while the server is down; a same-Bead launch is refused | fixed | Steps 21 and 22: definite down gives `failed`, reap works, and the same-Bead launch passes the live check. `scripts/session-herdr-server-down.test.sh` passed. |
| D3 | Logs are neither live nor bounded | fixed | Live growth on both backends (steps 18 and 33). The bound and the archiving of every generation are covered only by `scripts/session-log-writer.test.sh`, because no live log reached 1 MiB. |
| D4 | Codex `nudge --message` false positive | fixed | Steps 12 and 33 through `codex queue`. The pane fallback is covered only by `scripts/session-nudge-agents.test.sh`. |
| D5 | Antigravity `send --verify` and `nudge --message` false failures | fixed | Steps 13–15. |
| D6 | Cleanup kills the shared tmux server | fixed (code and test only) | Step 36. Not triggered live, by operator instruction. |
| D7 | Codex exact resume unsupported | fixed | Step 32, after stop and after restart. `scripts/codex-exact-resume.test.sh` passed. |
| D8 | A stray unlabelled root pane survives | fixed | Step 39 (two fresh workspaces). The previous version's leftover pane is reported by doctor and not auto-closed, as designed (step 19). |
| D9 | Server and record PIDs are namespace-local | fixed | Steps 2, 3, 35 and 40–42. `scripts/session-herdr-namespace.test.sh` passed. |
| D10 | The task-done broker ticks the launch checkout | fixed in the broker; live tick after this commit | Step 38. One client-side deviation from the design for old brokers (N1). |

## Deviations

- **Task checks instead of the runbook.** This run is the TASK-HHB-012 live
  re-acceptance, not the 18-step `docs/acceptance.md` runbook. The step table
  lists the previous report's checks plus the design Decision 13 checks.
- **No install path.** No packed or `npx` install was exercised. All commands
  ran from the implementation worktree, which is tree-identical to develop
  `c3c2231`. Session records live in that worktree's gitignored
  `.nogging/state/sessions/`, and the herdr server state is shared under the
  main checkout. The D1 foreign session (`SPEC-9nqv`) wrote one record into
  the main checkout's gitignored state; it was retired by name there.
- **Host-side operator actions.** This Lead runs fenced, so these actions ran
  through `tmux -L nogging run-shell`, in the host PID namespace:
  - `session herdr-server start`, four times: the first start, the restart
    in step 23, the idempotency check in step 41, and the start for the extra
    checks in steps 9 and 43;
  - `recover` in the main checkout (step 37);
  - `session list` and `session stop` of the Claude session (step 42);
  - read-only checks: namespace links, `/proc/<pid>/stat` start times,
    process trees, the environment variable *names* (no values) of the
    server and of the Claude agent, socket `stat`, and the Codex resume argv.
- **Other operator actions on Nogging-owned panes and the Nogging-owned
  server.**
  - Pending input was typed with `herdr pane send-text` (step 8) and with
    `tmux send-keys -l` (step 43).
  - The previous run's legacy root pane `w1:p1` (unlabelled, cwd of the
    deleted `nogging-spec-emer` worktree) was closed with `herdr pane close`
    after doctor had reported it. This let a fresh workspace, and with it
    D8, be observed.
  - `herdr --session nogging server stop` ran three times: the simulated
    restart, and twice at the end. Each time the receipt was first verified
    against the running server. No foreign herdr server existed: the
    `default` session was not running. Nothing else was stopped.
- **Step 9 re-run.** The first Claude `nudge --message` ran with wrapped
  pending input and exposed N2. A clean-prompt `nudge --message` was then run
  on a fresh Claude exact resume, so that step 9 regresses the previous run's
  check. That needed one more host-side server start and stop.
- **D6 not triggered.** The stopped tmux record
  `sf-lead-spec-17f0-20261016t061845-d612` was deliberately left unretired
  in the worktree state, so the worktree never reached "all records
  retired". With the D6 fix a later cleanup is expected to be safe, but this
  run did not show that live.
- **Lock check location.** The orchestrator lock was checked from the main
  checkout, because an implementation worktree does not see it (N4).
- **D10 ordering.** The live `task-done` tick follows the commit of this
  report (step 38).

## Discoveries filed during this run

All are recorded on `SPEC-dcuq` with the `discovery` label. None blocks this
Bead, because the report itself is the deliverable. None was fixed here;
they wait for a planning session.

| Bead ID | Blocking? | Summary |
| --- | --- | --- |
| SPEC-dcuq (N1) | no | **Code inspection, D10 follow-up.** `task_done()` in `scripts/nogg` retries the broker request without `checkout` when an old broker answers `only one closed Bead identifier`. Design Decision 4 ("Mixed versions") says that the client must report that the session needs a relaunch and must not retry without `checkout`. The retry brings back the D10 behaviour for any session that still runs an old broker. The retry came in with commit `5c914dd` (SPEC-hu81, the D6 fix), and no suite asserts the design behaviour. |
| SPEC-dcuq (N2) | no | **Both backends, live.** `nudge --message` does not fully clear wrapped pending input: the `ctrl+u` deletes only the current visual row in Claude Code. Stale text is merged into the message. On herdr, the merged text was submitted and reported `nudged`; on tmux, it was left pending and reported unsubmitted (exit 1). A clean prompt works. |
| SPEC-dcuq (N3) | no | **Docs only.** `docs/using-with-herdr.md` quotes the foreign-pane advisory as `NOTE N foreign Nogging pane(s) active on herdr server (not managed by this checkout)`, but the real output is `NOTE: 1 foreign herdr pane(s) left untouched`. The behaviour matches design Decision 7. |
| SPEC-dcuq (N4) | no | **Pre-existing, live.** Orchestrator lock readers are checkout-local. From an implementation worktree, `recover` shows no lock, and `orchestrator status` reports `lock: free`, no live orchestrator and a per-worktree unit name, while pid 926 holds the main checkout's lock. This misleads an operator in a worktree, and it could let a second orchestrator start from one. |

## Outcome

- **Overall:** pass-with-deviations
- **Summary:** Every defect that the hardening change targets is fixed on
  herdr 0.9.5 with all three runtimes:
  - D1, D2, D4, D5, D7, D8 and D9 were shown live, and D3 was shown live for
    log liveness, with its bound covered by test;
  - D6 is shown by code and test only, as instructed;
  - D10 is fixed in the broker; its live tick follows this commit.

  The orchestrator lock now reads as held from both the host and the sandbox
  at any age. The sandboxed-Lead topology works end to end:
  - a fenced launch is refused with a pointer to `session herdr-server
    start`;
  - the server runs in the host namespace with a socket-bound receipt;
  - terminal identity makes sessions live, stoppable and listable from both
    namespaces;
  - a stopped server is a definite state with a host-side recovery path.

  Exact resume works for Claude, Codex and Antigravity, both after stop and
  after a server restart and cleanup. The parallel tmux Lead was unaffected
  and shares the D3 and D4 fixes. The previously passing checks still pass.

  This is not a clean pass, for three reasons:
  - Step 43 fails. It is a new, backend-neutral nudge defect outside this
    change's scope (N2).
  - The D10 live tick and the D6 live condition were not exercised before
    this commit (steps 36 and 38).
  - The task-done client contradicts design Decision 4 for old brokers (N1).

  N3 is a wording error in the docs. N4 is a pre-existing worktree blind spot
  for the orchestrator lock. The herdr backend stays experimental, and tmux
  stays the default; whether this run accepts the hardening is the Product
  Owner's call at sign-off.

## Sign-off

A signed report is what marks the toolkit accepted for this run. Leave this line
blank in the commit that adds the report; a person fills it in a later commit.

Signed-off-by:
