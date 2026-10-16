# Nogging acceptance report — 2026-10-16 — raspberrypi (herdr session backend)

Unsigned execution evidence for TASK-HDR-012 (`SPEC-emer`) of the change
`add-herdr-session-backend`. This is the real Pi acceptance of the
experimental herdr backend. It runs one `--backend herdr` Lead session each
for Claude, Codex and Antigravity through send, nudge (with and without
`--message`), log, `AGENT_STATUS`, stop, a simulated server restart, reap,
cleanup and exact resume. A tmux Lead runs in parallel as a regression check.
The report follows `docs/acceptance-report-template.md`. The step table lists
the task's checks instead of the 18 general runbook steps (see Deviations).

The `Signed-off-by:` line is left blank. Only the Product Owner signs.

## Run metadata

| Field | Value |
| --- | --- |
| Date started | 2026-10-16 (00:14–00:36 UTC) |
| Host | `raspberrypi` (Linux aarch64, kernel 6.18.50+rpt-rpi-2712) |
| Operator | Nogging Lead session `sf-lead-spec-emer-20261016t001354-b18b` (Claude Code, Opus 5.5), on behalf of the Product Owner |
| Toolkit version | package `nogg` 2.2.0 (`.nogging/config.json` has no `nogging_version` key) |
| Git commit | `0098baf` (develop = origin/develop; implementation worktree `/home/jome/src/nogging-spec-emer`) |
| Runbook revision | `c8e2f6a` (`docs/acceptance.md`; not followed, see Deviations) |
| Install path exercised | none; live run of `./scripts/nogg` from the implementation worktree checkout |
| Backend | real `bd` 1.2.2 + `dolt` 2.3.1 |
| herdr | 0.9.5 at `~/.local/bin/herdr` (client protocol 22, `endpoint_protocol_generation` 1) |
| Agent runtimes | Claude Code 2.1.301, Codex CLI 0.162.1, Antigravity (`agy`) 1.3.6 |
| Other tools | tmux 3.5a, Python 3.13.5, Node v22.23.2, Git 2.47.3 |

## Setup

- **Throwaway Beads.** These Beads carried no real work. Each was claimed as
  soon as it was created, so no dispatcher could pick it up, and all were
  closed at the end:
  - `SPEC-92qu` for Claude;
  - `SPEC-lpu0` for Codex;
  - `SPEC-w6pn` for Antigravity;
  - `SPEC-036m` for the tmux regression;
  - `SPEC-b8wd` as the restart trigger (see D2).

  Launch allows only one live Lead per Bead, so each session needed its own
  Bead. A second Claude launch on `SPEC-92qu` was refused with `a live lead
  session already covers SPEC-92qu`.
- **Least authority and low cost.** Every session ran with `--role lead
  --profile restricted --prompt no-autonomous-claim --tier routine` and
  `--cwd /home/jome/src/nogging-spec-emer`. The models were
  `claude-sonnet-5-5` (effort low), `gpt-6-luna` (effort low) and
  `gemini-3.8-flash-low`. Every probe was a one-word echo prompt
  (`HERDR-<AGENT>-<STEP>`) that used no tools. Codex used 26% → 27% of its
  5-hour window.
- **Representative commands.** Each was run from the worktree checkout:

```bash
./scripts/nogg session launch --backend herdr --role lead --bead SPEC-92qu --agent claude \
  --profile restricted --prompt no-autonomous-claim --tier routine --cwd /home/jome/src/nogging-spec-emer
./scripts/nogg session send --verify <name> "Acceptance probe: reply with exactly the single word HERDR-CLAUDE-SEND ..."
./scripts/nogg session nudge <name>
./scripts/nogg session nudge <name> --message "Acceptance probe: reply with exactly ... HERDR-CLAUDE-NUDGE-MSG ..."
./scripts/nogg session list
./scripts/nogg session log <name>
./scripts/nogg session attach <name> --read-only
./scripts/nogg session stop <name> --reason "..."
herdr --session nogging server stop          # simulated restart, Nogging-owned server only
./scripts/nogg session reap
./scripts/nogg session cleanup [<name>]
./scripts/nogg session launch ... --resume c67203b0-611b-44c5-92b9-cd548f797902   # Claude
./scripts/nogg session launch ... --resume 90269e4d-8a35-40e6-9fdf-74987c93e565   # Antigravity
./scripts/nogg doctor
```

## Step results

Each Result is `pass`, `fail` or `skipped`. D1–D9 refer to the discoveries
listed below.

| # | Tag | Step | Result | Note |
| --- | --- | --- | --- | --- |
| 1 | [M] | doctor before any herdr record | pass | No herdr line; exit 0. |
| 2 | [A] | Dedicated server start | pass | The first herdr launch started `herdr --session nogging server`. Its config, passed through `HERDR_CONFIG_PATH`, holds exactly `resume_agents_on_restore = false`, `version_check = false`, `manifest_check = false` and `pane_history = false`. The server environment holds only `HERDR_CONFIG_PATH HOME LANG LOGNAME PATH SHELL TERM USER XDG_RUNTIME_DIR`. The socket `~/.config/herdr/sessions/nogging/herdr.sock` has mode `0600`. The receipt and config are shared under the main checkout's `.nogging/state/herdr/nogging/`. |
| 3 | [A] | Claude herdr launch | pass | The record was written first. The session got its own labelled pane in workspace `w1`, with this process chain: `session-pty-recorder` → `session-log-writer` (own session) → wrapper → `openspec-sandbox` → `claude`. `HERDR_AGENT=claude` is set; `CLAUDECODE` and `TMUX` are absent. The first attempt used a scratch cwd under `/tmp` and stopped at Claude's workspace-trust dialog. That cwd was a setup error, not a herdr issue; the session was relaunched in the worktree (see Deviations). |
| 4 | [A] | Codex herdr launch | pass | Labelled pane. The startup turn processed the launch prompt and claimed nothing. `codex_thread_id` was resolved. |
| 5 | [A] | Antigravity herdr launch | pass | Labelled pane. The Stop hook captured `antigravity_conversation_id`, and herdr detects agent `agy`. |
| 6 | [A] | Claude `send --verify` | pass | Verified; the reply `HERDR-CLAUDE-SEND` appears in the pane. |
| 7 | [A] | Claude `nudge` without `--message` (placeholder) | pass | `nothing to nudge (the prompt shows only a suggested placeholder, not input); nothing was submitted`. ANSI capture distinguished the dim placeholder. |
| 8 | [A] | Claude `nudge` without `--message` (real pending input) | pass | Input was typed into the pane with `herdr pane send-text` as operator setup. The nudge resent it, and Claude answered `HERDR-CLAUDE-NUDGE-RESEND`. |
| 9 | [A] | Claude `nudge --message` | pass | `nudged`; answer `HERDR-CLAUDE-NUDGE-MSG`. |
| 10 | [A] | Codex `send` | pass | Delivered through `codex queue`; answer `HERDR-CODEX-SEND`. |
| 11 | [A] | Codex `nudge` without `--message` | pass | `nothing to nudge (the pane input cannot be positively identified); nothing was submitted`. |
| 12 | [A] | Codex `nudge --message` | fail | The text stayed unsubmitted in the Codex input box, yet the nudge reported `nudged` with exit 0. A later single Enter submitted it. tmux behaves identically (D4). |
| 13 | [A] | Antigravity `send --verify` | fail | The message was delivered and answered (`HERDR-AGY-SEND`), but the command exited 1 with `message still unsubmitted after a retry` (D5). |
| 14 | [A] | Antigravity `nudge` without `--message` | pass | Nothing submitted (input not positively identifiable). |
| 15 | [A] | Antigravity `nudge --message` | fail | Delivered and answered (`HERDR-AGY-NUDGE-MSG`), but exit 1 with `message still unsubmitted after a retry` (D5). |
| 16 | [A] | `attach --read-only` on herdr | pass | Refused with `herdr has no read-only client; use session log --follow` (exit 1). |
| 17 | [A] | `AGENT_STATUS` | pass | Observed `blocked` (trust dialog), `idle`, `working` (during a turn), `done`, and `unknown` (at launch and while the server was down). Shows `-` for tmux and terminal records. |
| 18 | [A] | `session log` | fail | Antigravity logged live (67–97 KB). The Claude and Codex logs did not grow while their sessions ran: Claude stayed at 4,527 B and was 13,795 B after stop. Codex produced a 3,066,138 B `.log.1` with 9 LFs, against `session_log_max_bytes` 1,048,576; cleanup did not archive that `.log.1`. The writer survived pane close and the server stop and flushed its tail. The tmux logs behave the same (D3). |
| 19 | [M] | doctor with herdr records | pass | Exit 0, with three NOTE lines: `herdr: a server restart ends every Nogging herdr session (reaped as failed); plain herdr update in v0.9.5 keeps endpoint-generation-1 server sessions running`, `herdr records exist (4 non-retired); session_backend is tmux` and `herdr server (nogging): reachable (running)`. |
| 20 | [A] | stop on herdr | pass | Tested on Claude (including at the trust dialog), Codex, Antigravity and the trigger session. Each time the pane closed, the whole process tree ended, the record went to `stopped`, and `AGENT_STATUS` became `-`. |
| 21 | [A] | Server stop (simulated restart, part 1) | pass | Before `herdr --session nogging server stop`, the receipt's PID and start time were checked against the running server. The stop ended all three herdr agents; the tmux Lead kept running. The herdr CLI started no server on its own. While the server was down, list showed `running (unknown)`, and reap reported `liveness unknown; left records untouched`. |
| 22 | [A] | Recovery while the server is down | fail | A same-Bead exact resume was refused (`a live lead session already covers SPEC-92qu`). Only a launch on another Bead (`SPEC-b8wd`) restarts the server (D2). |
| 23 | [A] | Server restart (part 2) | pass | The new server got PID 14778 and a fresh receipt. Panes `w1:p6/p7/p8` returned with the same pane IDs and labels, as plain `/bin/bash`. No agent ran outside the wrapper. |
| 24 | [A] | list after restart | pass | The three records showed `failed`. Each restored pane was listed as `NOTE: orphan herdr pane … run session cleanup (never adopted)`. |
| 25 | [A] | reap after restart | pass | `reaped 3 vanished session(s)`. |
| 26 | [A] | cleanup after restart | pass | Retired 7 records and closed the restored panes. The herdr server kept running, and every tmux session (orchestrators and this Lead) stayed intact. |
| 27 | [A] | Last herdr record retired | pass | The herdr server kept running, and the unlabelled pane `w1:p1` stayed. doctor then printed no herdr line. |
| 28 | [A] | Claude exact resume after stop | pass | Same `claude_session_id` `c67203b0-…`. Claude recalled `HERDR-CLAUDE-SEND, HERDR-CLAUDE-NUDGE-RESEND, HERDR-CLAUDE-NUDGE-MSG`. |
| 29 | [A] | Claude exact resume after restart and cleanup | pass | Same ID; recalled `HERDR-CLAUDE-SEND`. |
| 30 | [A] | Antigravity exact resume after stop | pass | Same conversation `90269e4d-…`; recalled `HERDR-AGY-SEND, HERDR-AGY-NUDGE-MSG`. |
| 31 | [A] | Antigravity exact resume after restart and cleanup | pass | Recalled `HERDR-AGY-SEND`. The first send during the resumed startup turn was refused by design (`first turn has not finished`); a retry delivered it. |
| 32 | [A] | Codex exact resume | fail | `exact resume is supported only for Claude and Antigravity`, refused before any side effect (D7). |
| 33 | [A] | Parallel tmux Lead regression (Codex) | pass | Ran through the whole herdr run on `tmux -L nogging`. The mixed list showed `BACKEND tmux` and `AGENT_STATUS -`. Send through `codex queue` was answered (`TMUX-CODEX-SEND`), and a nudge without a message submitted nothing. The session was unaffected by the herdr stop and restart, then stopped cleanly; the log flushed only at stop. Nudge `--message` failed exactly as on herdr (D4). |
| 34 | [A] | Cross-checkout isolation of herdr cleanup | fail | Found by code inspection, not reproduced live (D1). |
| 35 | [A] | Server started from a sandboxed Lead | fail | Live evidence: the receipt's PIDs belong to the Lead's PID namespace (D9). |

## Deviations

- **Task checks instead of the runbook.** This run is the TASK-HDR-012 live
  acceptance, not the 18-step `docs/acceptance.md` runbook. The step table
  lists the task line's checks.
- **No install path.** No packed or `npx` install was exercised. All commands
  ran from the implementation worktree, which is tree-identical to develop
  `0098baf`. Session records live in that worktree's gitignored
  `.nogging/state/sessions/`. The herdr server state is shared under the main
  checkout.
- **First Claude launch.** The first launch used a scratch clone under
  `/tmp` as its cwd and stopped at Claude's workspace-trust dialog, because
  that path is not trusted. Accepting the dialog by keystroke would have
  emulated operator consent, so the session was stopped, which also tested
  stop, and relaunched with the worktree as its cwd. The worktree is under
  the trusted `/home/jome/src`.
- **Simulated restart.** The restart was `herdr --session nogging server
  stop` on the Nogging-owned server, after its receipt PID and start time
  were verified, followed by a server start through Nogging's next launch.
  That launch had to use the extra throwaway Bead `SPEC-b8wd` (D2). No server
  was started by hand, and no foreign herdr server existed: the `default`
  session was not running. At the end of the run the Nogging-owned server was
  stopped again, after its receipt was verified.
- **Operator setup actions.** These actions went straight to Nogging-owned
  panes:
  - Typing pending input with `herdr pane send-text` (step 8).
  - One diagnostic `herdr pane send-keys … enter`, which submitted the stuck
    Codex nudge text (step 12).
  - `tmux send-keys C-u` on the tmux Codex pane, which did not clear the
    Codex input.
- **Host-namespace check.** A read-only `tmux -L nogging run-shell` (readlink,
  ls and `/proc` cmdline) obtained the host PID namespace view for D9. This
  Lead itself runs inside the openspec-sandbox PID namespace.
- **Unretired tmux record.** To avoid D6, the stopped tmux record
  `sf-lead-spec-036m-20261016t002338-0921` was deliberately left unretired in
  the worktree state. The herdr records were retired one by one by name.
  **Do not run `session cleanup` in `/home/jome/src/nogging-spec-emer`**: once
  its last record retires, cleanup stops the shared tmux server.

## Discoveries filed during this run

All are recorded on `SPEC-emer` with the `discovery` label. None blocks this
Bead, because the report itself is the deliverable. Several block release
readiness of the herdr backend (see Outcome). None was fixed here; they wait
for a planning session.

| Bead ID | Blocking? | Summary |
| --- | --- | --- |
| SPEC-emer (D1) | no | **herdr, code inspection.** `HerdrBackend.orphans()` treats every `sf-` pane in the shared workspace that this checkout's records do not own as an orphan. Records are kept per checkout, but the herdr server and workspace are shared across checkouts. Cleanup in one checkout can therefore close another checkout's live herdr panes. |
| SPEC-emer (D2) | no | **herdr, live.** While the dedicated server is down, records stay `running (unknown)` and a same-Bead launch, including exact resume, is refused. Only a launch on another Bead restarts the server. The docs cover only the "server restarted" case. |
| SPEC-emer (D3) | no | **Both backends, live.** `session-log-writer` is line-based, but the Claude 2.1.301 and Codex 0.162.1 full-screen TUIs emit almost no LF. Their logs freeze while the session runs, the writer holds the whole stream in memory, and the size bound is violated (a 3,066,138 B `.log.1`). As a result, `session log --follow`, the documented herdr substitute for a read-only attach, shows nothing live. |
| SPEC-emer (D4) | no | **Both backends, live.** Codex `nudge --message` leaves the text unsubmitted but reports `nudged`: a false-positive verification. |
| SPEC-emer (D5) | no | **Backend-neutral code, live on herdr.** Antigravity `send --verify` and `nudge --message` fail with "still unsubmitted" although the message was delivered. The generic last-line check sees agy's permanent status bar. |
| SPEC-emer (D6) | no | **Pre-existing tmux behaviour, code inspection.** When the current checkout's records are all retired, cleanup runs `tmux kill-server` on the shared `-L nogging` server. That kills the orchestrator and other checkouts' sessions. Deliberately not triggered. |
| SPEC-emer (D7) | no | **Plan gap.** The task requires Codex exact resume, but `--resume` supports only Claude and Antigravity. Codex resume therefore stays unaccepted. |
| SPEC-emer (D8) | no | **herdr, minor.** `workspace create` leaves an unlabelled `/bin/bash` pane in the Nogging-owned server. It survives restarts and is never cleaned up. |
| SPEC-emer (D9) | no | **herdr, live, significant.** A Lead runs inside the openspec-sandbox PID namespace. When it starts the shared server, the receipt and record PIDs are namespace-local: receipt PID 1050 was the herdr server inside the sandbox but `dolt sql-server` on the host. Liveness and ownership checks are therefore wrong across namespaces, and the server dies with the starting Lead's sandbox. |

## Outcome

- **Overall:** fail
- **Summary:** The core herdr lifecycle works on herdr 0.9.5 for all three
  runtimes. It covers:
  - a dedicated, isolated server with a scrubbed environment and a `0600`
    socket;
  - labelled panes behind the unchanged launch wrapper;
  - process-bound liveness, including `unknown` while the server is down;
  - a correct `AGENT_STATUS`;
  - Claude steering, including placeholder-safe nudges;
  - stop;
  - a server restart that reconciles records to `failed`, with restored
    panes never adopted;
  - reap and cleanup that keep the server;
  - exact resume for Claude and Antigravity, both after stop and after a
    restart;
  - an unaffected parallel tmux Lead and correct herdr doctor reporting.

  The run does not accept the task as specified:
  - Codex exact resume is unsupported (D7).
  - `nudge --message` gives wrong verification results for Codex (D4) and
    Antigravity (D5).
  - Claude and Codex logs are neither live nor bounded (D3).
  - There is no recovery path while the server is down (D2).
  - Two herdr-specific isolation defects make the backend unsafe in the
    normal multi-checkout, sandboxed-Lead topology: cross-checkout orphan
    cleanup (D1) and namespace-local server and record PIDs (D9).

  D3–D6 also affect tmux or predate this change. D1, D2, D8 and D9 are
  herdr-specific. tmux stays the safe default.

## Sign-off

A signed report is what marks the toolkit accepted for this run. Leave this line
blank in the commit that adds the report; a person fills it in a later commit.

Signed-off-by:
