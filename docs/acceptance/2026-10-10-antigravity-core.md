# Antigravity core runtime acceptance — 2026-10-10

Unsigned execution evidence for TASK-AGR-008 (`SPEC-ry18`),
`support-antigravity-runtime`, and GitHub issue #54. This covers core runtime
behavior only; quota acceptance (TASK-AGR-005, `SPEC-43k1`) is appended as an
unsigned addendum at the end of this report. Issue #54 remains open for the
Product Owner; this report does not authorize release, archive, or human
acceptance.

## Environment

Linux delivery host; agy 1.3.2, Node v22.23.2, Python 3.13.5,
tmux 3.5a, Beads 1.2.2. Implementation worktree:
`/home/jome/src/nogging-spec-ry18`, branch `chore/agy-acceptance`,
allocated at integrated AGR-007 baseline `1f0a750`.
The Main Worker is Codex; real Antigravity Lead and separate code-reviewer
sessions exercise the packed consumer. These are supervised probes, not a
claim of an independently autonomous Antigravity delivery run.

Every agy process disables auto-update. Runtime credentials stay in their
original location; none are copied into a scratch HOME or recorded here.

## Findings fixed during acceptance

The shipped `Stop` entry used a grouped `hooks` wrapper. Installed agy docs
require flat Stop handlers. Two real startups acknowledged readiness but never
recorded Stop or conversation IDs, leaving send waiting for startup readiness.
The investigation fixture also wraps raw stdin with its recorder's cwd; the
runtime itself sends direct fields. The validator incorrectly consumed that
recorder wrapper.

The template and preflight now require flat handlers; event ingestion accepts
raw stdin and still validates agent, exact workspace, UUID, fullyIdle and
executionNum, refusing ID changes. The lifecycle regression exercises the
actual shell hook with raw stdin, rejects recorder envelopes and malformed
fields, and retains concurrent single-kickoff checks. Both discoveries are
recorded on SPEC-ry18. Consumers need `nogg update` before launching the repaired
runtime; existing malformed installed hooks refuse preflight.

## Commands and observed results

Packed consumer commands (run with inherited Nogging session variables removed
for test isolation, and `npm_config_cache=/tmp/ry18-npm-cache`):

```bash
npm pack --json --pack-destination /tmp/ry18-consumer
tar -xzf /tmp/ry18-consumer/nogg-2.1.0.tgz -C /tmp/ry18-consumer
git init -q /tmp/ry18-consumer/repo
cd /tmp/ry18-consumer/repo
node ../package/bin/cli.js init --no-systemd --no-beads --no-hooks
node ../package/bin/cli.js update --no-systemd --no-hooks
node ../package/bin/cli.js update --no-systemd --no-hooks
```

Repacked and updated after both repairs. A valid unrelated `consumer-owned`
Stop handler survived repeated update. Installer tests additionally cover
ordered named-hook merge, helper modes, upgrade and managed-only removal.
The live removal check follows session shutdown and verifies that unrelated
hook and consumer marker files survive while managed entries disappear.

Live launches from the implementation checkout:

```bash
./scripts/nogg session launch --agent agy --role lead --bead SPEC-ry18 \
  --cwd /tmp/ry18-consumer/repo --profile trusted
./scripts/nogg session launch --agent agy --role specialist:code-reviewer \
  --bead SPEC-ry18 --cwd /tmp/ry18-consumer/repo --profile restricted
./scripts/nogg session send <name> '<acceptance probe>'
./scripts/nogg session stop <lead-name> --reason 'Exact resume acceptance'
./scripts/nogg session launch --agent agy --role lead --bead SPEC-ry18 \
  --cwd /tmp/ry18-consumer/repo --profile trusted --resume <captured-id>
```

| Check | Observed result |
| --- | --- |
| Missing source-worktree hook | Launch refused before starting agy; packed consumer supplied installed hooks |
| Bare launch | Acknowledged readiness; no claim or implementation began |
| Trust | Only selected consumer path added; global permission setting preserved |
| Startup/Stop | Corrected Lead and specialist captured real IDs and ready timestamps; turn_end events append |
| Trusted effect | `printf AGR_TRUSTED_OK > trusted-effect.txt` ran without permission prompt; exact file content verified |
| Restricted permission | `printf AGR_RESTRICTED_OK > restricted-effect.txt` displayed `Run this command?` with guard review reason; file absent before approval and exact content present after one-time approval |
| Command floor, both levels | `curl --version` denied by PreToolUse; agent reported hook denial and did not retry |
| Execution OpenSpec boundary | Disposable-consumer `printf SHOULD_BE_DENIED > openspec/acceptance-probe.txt` denied; target absent |
| Exact resume | New Lead record retained exactly the old captured conversation ID and captured a new Stop; recalled `AGR_RESUME_ry18` after restart without tools |
| Specialist boundary | Separate restricted code-reviewer returned structured results; no claim, status, close or commit action |
| Stop | Supervised sessions transitioned to stopped; no scratch agent remains running |

The live restricted prompt used the existing verified request-review setting;
no permanent command allowance or global permission-mode change was selected.
Always-proceed refusal, malformed trust/settings, missing guard, sandbox refusal
and scoped atomic trust preservation are covered by the launch/guard tests;
this run did not switch the operator's global mode to always-proceed.

## Real Bead and validation evidence

SPEC-ry18 is the real claimed Lead Bead for this run. Implementation and
validation happen in its allocated worktree. The Main Worker retains ownership
of the acceptance repair, evidence commit, closure and task-done broker tick;
Antigravity probes and the separate specialist neither claim nor close it.
Its native notes hold the final commit SHA and validation evidence. The mapped
TASK-AGR-008 tick is produced only by task-done after closure, never by hand.

`scripts/test` passed once with inherited session variables removed before the
repairs. The repaired suite also passed under the same isolation, with
`bash scripts/antigravity-lifecycle.test.sh` checking the final raw-payload
regression and `git diff --check` before commit. The first suite attempt retained
real session variables and failed fixture boundary checks; it is not counted as
passing evidence. Live launches retain their real session boundary.

## Limits and sign-off

No filesystem/network isolation or sandbox compatibility is claimed. Multi-edit
contracts remain unsupported. No quota was exhausted and no admission/reset
mapping or quota adapter is accepted here. AGR-005 and full issue #54 completion
remain pending. Headless SUCCESS/exit zero is never the sole execution oracle;
this run checks files, permission UI, hook denials and recorded lifecycle events.
Human acceptance remains unsigned.

Signed-off-by:

## Quota acceptance addendum — 2026-10-11 (TASK-AGR-005, `SPEC-43k1`)

Unsigned execution evidence for the Antigravity pane adapter and quota source
wired into the launch usage gate. It is appended to, and does not revise, the
core findings above.

### Environment

Linux delivery host; agy **1.3.3** (the 1.3.2 core evidence above is
unchanged), Node v22.23.2, Python 3.13.5, tmux 3.5a. Baseline `e6ff4d5`
(develop after GSU-006), implementation worktree `nogging-spec-43k1`, branch
`feat/antigravity-quota-source`. The packed archive is `npm pack
--ignore-scripts` of that worktree. Every agy process disables auto-update; no
credential was copied or printed. Live sessions were launched only through the
supervised `scripts/nogg session launch` path.

### What changed

- `scripts/nogg_usage.py`: Antigravity quota source. A bounded `agy --print
  /usage --output-format json` probe from a private neutral directory, a
  sanitized owner-only cache reused for `usage_gate.stale_seconds`, model ->
  group selection from the runtime's own group descriptions, weekly and 5h
  buckets as separate windows, and resume guidance over every exhausted bucket.
- `scripts/nogg`: `antigravity` pane adapter; the gate, end-of-session history
  and `nogg usage --agent agy` observe by selected model; `session
  resume-when-ready` and the `limit` watch event take the reset from quota
  buckets.
- Fixtures: `scripts/fixtures/antigravity/1.3.3/usage.json` and
  `panes/{idle,working,needs_input}.txt`, recorded live.

### Live observations (agy 1.3.3)

| Check | Result |
| --- | --- |
| `nogg usage --agent agy --model gemini-3.8-flash-medium` | group `Gemini Models`; 5h 56.45% used (reset 17:32:52Z), weekly 35.37% (reset 2026-10-13T20:14:27Z); fits |
| `--model claude-sonnet-4-6` | group `Claude and GPT models`; 5h 0%, weekly 50.40%; independent of Gemini |
| `--model mystery-model` / no model | both windows `unknown (unknown model mapping)`; never zero |
| Cache | `antigravity.json` mode 0600 in a 0700 directory; fresh cache served the next three calls without a probe |
| Gated live launch (restricted, `--model gemini-3.8-flash-low`) | admitted; record carries `usage_gate.start_observation.model_group = Gemini Models` and both known buckets |
| Pane adapter on the live pane, one turn | `idle` -> `working` -> `needs_input` (`Run this command?`) -> `unknown` while the tool ran -> `idle` |
| Stop hook | conversation ID captured in the session record; `session stop` recorded `stopped` |
| Exact resume through the gate | `--resume <captured id>` admitted; recorded ID equals the requested ID |
| Exit 75 against the real runtime | scratch root, `usage_gate.cap_percent = 50`: short bucket 56.45% + 5% > 50% denied with exit 75 naming the reset; `~/.gemini/antigravity-cli/settings.json` byte-identical (SHA-256 before = after), tmux session count 5 -> 5, no session record |

The exit-75 run used a scratch consumer with a stub `bd` only; the runtime,
tmux and trust file were the real ones, so it exercises the pre-trust ordering
(the gate precedes guard validation, trust preparation and tmux).

### Fixture and unit evidence

`scripts/antigravity-usage.test.sh` covers: live idle/working/needs_input panes
plus imported trust and exhausted-credit wording as `limit`, with transcript
text unable to flip an idle pane; normalization keeping allowlisted fields;
headless exit zero with a non-SUCCESS status, denied actions, an error, a
timeout, a nonzero exit, unparseable output or an unexpected command object all
unknown; model -> group mapping (unknown, ambiguous and description-less
mappings are unknown usage); independent reservation scopes per group;
weekly-limited versus short-limited denials with the latest reset in the retry;
an unrecognized extra window evaluated and duplicates/missing buckets unknown;
resume `wait` until the weekly reset when only the 5h window refreshed; the
resume loop; and real `session launch` runs for exit 75 before trust/tmux, the
other group admitted, unknown mapping warn/deny, and cache reuse.

### Packed consumer

`scripts/packed-antigravity-usage.test.sh` packs the repository, installs into
a consumer, and checks the installed payload from the archive: group selection
and `nogg usage --json`, exit 75 before trust and tmux for the exhausted group,
the other group admitted with only its worktree added to `trustedWorkspaces`
(unrelated entries kept), a non-SUCCESS probe reported as unknown, `update`
repairing a corrupted `nogg_usage.py`, and `remove` deleting it while keeping
the user's config. The archive contains no tests or bytecode.

### Core lifecycle regression

The full `scripts/test`, run with every inherited `NOGG_*`/`NOGGING_ROOT`
session variable removed, passed: 88 of 88 test scripts `PASS`, 0 `FAIL`,
final line `Nogging: all script tests passed`, exit 0. That includes the core
suites unchanged by this task (`antigravity-launch`, `antigravity-lifecycle`,
`agy-guard`, `session-tier`, `session-model-forwarding`,
`packed-model-selection`, `session-observability`) and the two new quota suites.
A first run without the probe opt-out was discarded: tests that scrub
`NOGG_`/`NOGGING_` variables reached the real runtime and timed out, which is
why the opt-out is named `AGY_NOGG_USAGE_PROBE`.
The live lifecycle above repeats the core path with the new gate: gated launch,
trust preparation before start, first-turn Stop capture, `send`, a restricted
permission prompt approved once, `stop`, and exact-ID resume.

### Limits

- No quota was exhausted. Exhausted-credit and limit wording
  (`Your AI credits balance is too low to continue.` and the usage-limit
  phrases) is imported, not observed live; it can only add a `limit` pane
  classification. Resume timing and denial never depend on that text: they come
  from `/usage` buckets, which were observed live only below the cap.
- Weekly-versus-short resume ordering is verified with derived fixtures (the
  recorded `/usage` result with `remaining_fraction` set to 0), not a live
  exhaustion.
- The trust dialog wording is the 1.3.2 investigation's; this run's trust
  preparation happened before launch, so it was not displayed.
- A pane showing a running tool classifies `unknown` (no running-tool marker
  was recorded), which is the honest result rather than `idle`.
- A probe from an unauthenticated or hung runtime can take up to its 45 s bound
  once per stale window; the test runner disables the probe
  (`AGY_NOGG_USAGE_PROBE=0`).
- Quota percentages are provider estimates for this account, not cost.
- Issue #54 is not closed by this report. Human acceptance remains unsigned.

Signed-off-by:
