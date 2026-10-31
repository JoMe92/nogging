# Session wake — delivery host acceptance — 2026-10-31

Unsigned execution evidence for TASK-SWK-008 (`SPEC-qzau`), change `session-wake`,
design Decision 14.

**Overall: partial, not accepted as it stands.** Real sessions on Claude Code, Codex and
Pi proved the core path: `turn_end` in `session watch`, a stop guard on a dirty tree on
every runtime, a `blocked` signal out of the Codex sandbox, fixed nudges, red and green
checks, and coalesced digests. One documented behaviour **failed**: a Codex usage limit
is not recognised. Pi can lose lifecycle events under load. Keep-warm, pause, quiet
hours and retirement were **not** shown live, and automated tests are not counted as
live results here. This report does not establish Product Owner acceptance.

## Run metadata

| Field | Value |
| --- | --- |
| Date | 2026-10-31, 10:16Z to about 12:05Z |
| Host | `raspberrypi`, Linux aarch64; one load reading at 10:32Z gave 16.6, 18.6, 13.3 |
| Operator | Nogging-supervised Claude Lead `sf-lead-spec-qzau-20261031t101654-6a0c` (`trusted`, autonomous) |
| Toolkit version | 3.5.0 (`package.json`) |
| Git commit | `837cd8c` at the start; the host checkout reached `4b5f954` during the run, because other work merged |
| Runbook | Design Decision 14 and TASK-SWK-008; not `docs/acceptance.md` |
| Backend | Real `bd` and Dolt, real `gh`, the real host dispatcher on its one-minute timer |
| Dispatcher | On by default, `retire_merged: true` in this repository, running since 2026-10-31 00:30Z |
| Throwaway Beads | `SPEC-ejqb` (Claude), `SPEC-9ipj` (Codex), `SPEC-as9r` (Pi), all closed; no probe branch was pushed |

| Tool | Version |
| --- | --- |
| Claude Code | 2.1.316 (the orchestrator itself runs an older, not yet restarted process) |
| Codex CLI | 0.164.0 |
| Pi | 1.4.0 |
| herdr | 0.9.5 |

| Probe | Backend, authority | Model |
| --- | --- | --- |
| Claude `…ejqb…a5a5` | tmux, `trusted`, launched with `--ignore-usage-gate` under the Product Owner's note on this Bead | `claude-sonnet-5-5`, low |
| Codex `…9ipj…6f9e` | tmux, `restricted`, in its real sandbox | `gpt-6-luna`, low |
| Pi `…as9r…a2ec` | herdr, `trusted` | `glm-5.3-flash`, low |

Evidence kept on the host: `.nogging/state/dispatch/dispatch.jsonl`, the session
`*.events.jsonl` files, the Codex rollout and the orchestrator transcript. All times are
UTC.

## Results

Result is `pass`, `partial`, `fail` or `skipped`. `skipped` means the behaviour was not
seen live, whatever the tests say.

| # | Check | Result | Evidence |
| --- | --- | --- | --- |
| 1 | `turn_end` with an excerpt in `session watch` | partial | Claude and Codex pass (`idle excerpt=gap seen`; `codex-hook`). Pi passes from its second turn on, and its first turn lost its events (Finding 2) |
| 2 | Stop guard continues a Lead with a dirty tree | pass | Each tree held an untracked `swk-probe.txt`, and each stop was continued once and then allowed: `guard_continue` then `turn_end` at Claude 10:25:12, Pi 10:29:33 (its first guard shows only in the pane), Codex 11:54:59. The Pi and Codex panes show `uncommitted changes`; Claude's later `stuck` item says the same |
| 3 | `session signal blocked` from the Codex sandbox reaches a digest | pass | Signal 11:56:02, queued 11:56:07, delivered 11:58:08 as `w-20261031T115808Z`, which matches `urgent_quiet`. The orchestrator answered in one message |
| 4 | Fixed nudge lands only when idle | partial | Claude: 10:28:11 and 10:29:12, each after a `turn_end`. Pi: 10:32:09 and 10:34:04. Both then reached `stuck`. Codex nudges landed on a session stopped by its limit (Finding 1) |
| 5 | Red check nudges the Lead | pass | Real Pi Lead, PR #350: 07:42:07 and 09:18:05, naming `invariants`, then `ci_stuck` at 09:19:06 once `max_ci_nudges` was spent |
| 6 | Green check produces `ready_for_review` | pass | PR #351 queued 10:59:08, held by the usage rule, delivered 11:04:09, merged 11:05:00. PR on `…ebeq…` queued 11:41:09, delivered 11:47:05 |
| 7 | Two items coalesced into one wake | pass | `w-20261031T103108Z items=2 urgent=1`: `stuck` and `ci_stuck` in one digest |
| 8 | Merged session retired when enabled | skipped | Never reached. The orchestrator's merge routine stops the session first: `…ykda…` at 10:33:56, `…ks3v…` 15 s after its merge at 11:05:15. No `retire` entry exists (Finding 4) |
| 9 | Keep-warm answered in one line with no tool call | skipped | None was sent. The one that fell due, at 08:25:05, was `held: usage weekly 94%`. After the 11:00Z reset, real turns kept resetting the 50-minute clock, and the run ended before another fell due |
| 10 | A short pause suppresses keep-warm and ends in one resume digest | skipped | `pause` and `resume` are refused in Lead sessions by design and were not attempted. See *What is left to run* |
| 11 | Quiet hours hold an item | skipped | Needs a window in the host's tracked config and a pass. `session dispatch --once` is refused in every supervised session, so a scratch consumer cannot run one from here |
| 12 | Scratch consumer with no `enabled` key | partial | Fresh `init`, key removed: `session dispatch --dry-run --json` printed `"enabled": true`, and `doctor` printed exactly one NOTE, `no orchestrator session, so 0 item(s) are held`, with no FAIL. Holding a real digest was not shown, for the reason in row 11 |
| 13 | Codex hook from a Lead worktree with `NOGG_SESSION_ROOT` set | pass | `source: codex-hook` from `/home/jome/src/nogging-spec-9ipj` |
| 14 | Native idle compaction or the fallback at the new threshold | skipped | Not observable. The orchestrator was not restarted after TASK-SWK-007, so its settings hold no budget, and restarting it was out of scope. Neither mechanism fired in the period. The only compaction was manual, at 07:16 |
| 15 | One warm and one cold wake | pass | See *Warm and cold* |
| 16 | How the quota weights a read against a write | skipped | Not separable; see *Warm and cold* |
| 17 | A comparable period against the baseline | partial | Measured, but not truly comparable; see *Against the baseline* |
| 18 | A usage limit waits, then resumes | fail | Not on the task's list, found on the way (Finding 1) |

`scripts/session-wake-integration.test.sh` and `scripts/session-guard.test.sh` pass on
this commit (159.6 s together). They cover pause and quiet hours with an injected clock
and fake runtimes, which supports rows 10 and 11 without replacing them.

## Findings

Recorded on `SPEC-qzau` with the `discovery` label. Nothing was fixed here; these wait
for a planning session.

1. **A Codex usage limit is read as idle (fail, verified).** The Codex account was at its
   limit on launch. The rollout's `task_complete` carries
   `error.codex_error_info: usage_limit_exceeded`, and the pane prints "You've hit your
   usage limit". The pane pattern only knows `usage limit reached` and `rate limit`, and
   the rollout error is not read. So the state was `idle`, not `limit`. The dispatcher
   sent two `no-pr` nudges one minute apart (10:27:11, 10:28:11), each an instantly failed
   turn, and queued `stuck` with the wrong reason: "idle, clean, no pull request and no
   signal". The limit lifted at 11:51 and **no resume was sent**; the session stayed idle
   until this run spoke to it. The usage gate could not stop the launch either, because
   Codex usage reads as unknown. The cost here was small, but a real Lead would sit
   parked behind a misleading item.
2. **Pi can lose lifecycle events under load (verified effect, likely cause).** On the Pi
   probe's first turn the guard fired in the pane, but `guard_continue` and `turn_end`
   never reached the event file. `session watch` and the dispatcher read `working` for
   five minutes and sent no nudge. Later turns recorded correctly. Likely cause: the
   extension's `EMIT_TIMEOUT_MS` is 3000, and it kills `scripts/nogg`, whose startup alone
   took 2.2 to 3.5 s at this host's load. That is measured, not proven by reproduction.
3. **A digest can carry a stale item.** `ci_stuck` on PR #350 was queued at 09:19, held 72
   minutes by the usage rule, and delivered at 10:31 as "CI still failing: invariants".
   The orchestrator checked and found `invariants` green. Item text should be read as
   true when queued. The cause was not established.
4. **`retire_merged` has no live candidate on this host.** The orchestrator stops a
   session in its own merge routine within seconds, so the dispatcher's step has not run
   on real work. This is a working-practice gap, and it leaves the feature unproven.

Two items were checked and are **not** defects. The expensive cold wake at 06:52 happened
because the orchestrator sat on `needs_input` from 00:31:37 to 06:54, and the dispatcher
rightly does not send to a pending question, so its cache lapsed. In the same way, items
that cleared on their own woke nobody: the Pi `stuck` item cleared at 10:37:08 when its
Bead closed.

## Warm and cold

First message of each wake, from the orchestrator transcript. E is input-equivalents at
list multipliers: read 0.1, write 2.0.

| Wake | Kind | Gap before | Read | Written | E |
| --- | --- | --- | --- | --- | --- |
| 06:52 | cold | 6 h 21 min | 27,455 | 635,746 | 1,274,237 |
| 10:09 | cold | 2 h 35 min | 27,455 | 61,639 | 126,024 |
| 10:16 | warm | under 1 h | 90,659 | 436 | 9,938 |
| 11:58 | warm | under 1 h | 126,604 | 222 | 13,104 |

At about 90k of context, cold cost 12.7 times warm, not the 20 to 40 the design estimated
from multipliers alone, because a 27k system prefix stays cached across a lapse.

The quota weighting could **not** be isolated. `nogg usage` reports whole percents, and
other Claude sessions ran throughout. Across all Claude transcripts, the 5-hour window
rose 9 % over 10:20 to 10:35 (7.39M E) and 5 % over 10:35 to 10:59 (4.50M E), so 0.82M
and 0.90M E per percent. That agrees with list prices, but solving those two intervals
for the write multiplier gives anything from about 0 upward once rounding is allowed.
Separating them needs a Claude-only quiet window with a single wake.

## Against the baseline

Both rows use one script on one transcript, with wakes split at a 120 s gap. The design's
baseline was cut at slightly different boundaries (577 messages, 61 wakes), so this row
differs from it a little.

| Measure | Baseline, 10-27 to 10-30 | Dispatch, 00:30Z to 12:00Z | After the 07:16 compaction |
| --- | --- | --- | --- |
| Span | 3.50 days | 0.48 days | 0.20 days |
| Wakes, per day | 74, 21.1 | 12, 25.1 | 10, 51.0 |
| Messages per wake, median / mean | 8 / 9.1 | 6.5 / 8.2 | 6.5 / 8.1 |
| Mean context, peak | 334k, 552k | 197k, 671k | 99k, 127k |
| Tokens per wake, median / mean | 2.20M / 3.03M | 0.80M / 1.61M | 0.58M / 0.80M |
| Tokens per day, raw | 64.1M | 40.4M | 40.9M |
| E per wake, mean | 383k | 304k | 124k |
| E per day | 8.10M | 7.61M | 6.33M |
| Cold wakes | 10 | 2 | 1 |

Read this with care. The period is one busy release day, not 3.5 days, and it includes
this run's own probes, so wakes per day is not a fair comparison. Most of the drop in
context and tokens per wake comes from a **manual** compaction at 07:16, not from the
dispatcher. Nine digests went out, carrying the decisions directly. The orchestrator
still ran its own background jobs, so the self-made polling the baseline found is
reduced, not gone.

## What is left to run

Each of these needs the operator or a config change, which a Lead must not make:

- **Keep-warm and pause:** from an operator shell, while the orchestrator has been idle
  for about 47 minutes with a Lead running, run `./scripts/nogg pause --until <in five
  minutes>`, then read `session inbox`. It has to be the operator's shell, because a
  pause through the orchestrator is itself a turn, which resets the idle clock.
- **Keep-warm alone:** watch `dispatch.jsonl` after any 50-minute idle stretch with work
  active.
- **Quiet hours:** add a window covering the next few minutes to `session_dispatch.wake`
  on the host, then leave one item queued.
- **Retirement:** leave one merged Lead running with a closed Bead and a clean tree for
  two passes.
- **Native compaction:** restart the orchestrator from an external shell when it is idle,
  so the budget applies, then observe one idle stretch.

## Deviations

- The scratch consumer ran beside the main checkout, not in place of it, for row 12 only.
- Real work stood in for probes in rows 5 and 6, because live Leads supplied it. No
  throwaway PR was opened.
- The Codex probe declined its file step, so the file for the dirty-tree guard was placed
  by the supervising Lead. The guard, the hook and the turn were real.
- The Codex scenario ran 90 minutes late, after its limit reset.
- `./scripts/nogg worktree rebase` refused with "requester session does not own this
  checkout", so this report sits on the branch's original base. Nothing was routed around.

## Sign-off

A signed report is what marks this run accepted. This line stays blank in the commit that
adds the report; a person fills it in a later commit.

Signed-off-by:
