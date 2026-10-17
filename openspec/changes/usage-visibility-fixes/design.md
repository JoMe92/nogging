## Context

Four defects from #211, in two files (`scripts/nogg_usage.py`, `scripts/nogg`).
Each is its own task on its own branch, run in parallel, edits only its named
region, and ships a focused test. The first three are independent code fixes;
the fourth is visibility only.

## Goals / Non-Goals

**Goals:** a Codex weekly window at 98 % denies instead of admitting; Antigravity
table models map and the no-model case says what to do; operators see the
Claude statusline remedy; unknown-admitted launches are loud and `doctor`
explains the policy.

**Non-Goals:** changing the `on_unknown` default or adding `unknown-blocked`
(PO decision); Claude/Antigravity staleness; per-account identity; fixing #163.

## Decisions

### 1. Test discipline (every task)

Add or extend the named focused suite, update superseded assertions in the same
commit, run `scripts/test`. Fixtures use scratch `CODEX_HOME` / `XDG_CACHE_HOME`
(see the exports at the top of `scripts/usage-gate.test.sh`), inject `now`
rather than sleeping, and never read the operator's live quota or run `agy`.
Leads read Decision 1, their own Decision, their task line and the spec delta.

### 2. Codex observation lives until reset (TASK-UVF-001)

Codex writes a `token_count` event with both windows' `used_percent` and
`resets_at` on every turn on this host, so the newest event is the host's
latest knowledge; usage within a window only grows, and only other machines
can make it older than the log. In `inspect_usage()` for `agent == 'codex'`
drop the `age > stale_after` expiry. Each window stays valid while its own
`resets_at > now` (existing `reset elapsed; fresh observation required`
unchanged, evaluated per window). Add `stale: true` to a window (and report) when
`age > stale_after`, purely informational; `observed_at` already carries the
time. A future-dated observation still reports `observation is in the future`.
`stale_after` continues to apply to Claude and Antigravity unchanged.

Consequences to cover in tests: 15-minute-old observation with weekly 98 % and
future reset → known, gate `denied` naming the weekly reset; same age, both
fitting → `admitted`; short reset elapsed + weekly known and fitting → short
unknown (`reset elapsed`), decision `unknown-admitted`; weekly over cap with
short elapsed → still `denied`. `nogg usage` text appends `; stale (observed
<age> ago)` to a stale known window. Update `test_timezone_stale_future_and_reset`
in `scripts/usage.test.sh` and the stale-warns assertion near
`scripts/usage-gate.test.sh:236` (switch that fixture to a Claude cache, which
still expires) in the same commit. Doctor's Codex note (the Codex region of
`quota_freshness_notes()`): an aged but unreset observation reports
`observation is N old but windows have not reset — still used`.

### 3. Antigravity mapping coverage (TASK-UVF-002)

`agy_select_group()` returns `'unknown model mapping (no model selected; pass
--model <id>)'` for an unset/blank model and plain `'unknown model mapping'`
for an unrecognised family; the `ambiguous` case is unchanged. The prefix
`unknown model mapping` is preserved so the existing launch-warning substring
assertions still match. Add a drift guard to `scripts/antigravity-usage.test.sh`:
read every `agents.antigravity.<tier>.model` from `.nogging/model-selection.json`
(and the packaged default asserted by `scripts/packed-model-selection.test.sh`
if it differs), build groups with the real probe description shape
(`Models within this group: Gemini Flash, Gemini Pro` /
`Claude Opus, Claude Sonnet, GPT-OSS`), and assert each resolves to exactly one
group with both buckets known. A launch through `--tier` reaches the gate with
the table model (`selected_model`); assert that path produces a known gate for
a fixture cache. Update the `(None, '')` expectations at
`scripts/antigravity-usage.test.sh:97` and add a sentence to
`docs/using-with-antigravity.md`: bare `nogg usage --agent antigravity` needs
`--model`.

### 4. Remediation hints for missing sources (TASK-UVF-003)

Windows gain an optional additive `hint` string (absent when none). In
`inspect_usage()` for Claude with `reason == 'missing usage source'` set
`hint = 'run nogg usage install-statusline'` on both windows. `evaluate_gate()`
copies `hint` into each projected window. `nogg usage` text prints
`unknown (missing usage source) — run nogg usage install-statusline`. Doctor's
Claude note already names the command when the cache file is absent; add a
test proving it is emitted (and that an unreadable-cache note also carries it
for `missing usage source`). The launch warning is owned by TASK-UVF-004, which
appends `w.get('hint')` generically; this task does not edit
`usage_gate_admission()`. The hint is advisory text; no behaviour or decision
changes. New suite `scripts/usage-hints.test.sh`.

### 5. Loud unknown-admitted warning and doctor note (TASK-UVF-004)

Keep `on_unknown: warn` as default. In `usage_gate_admission()` replace the
`warning: …` line with a multi-field `WARN` on stderr:
`WARN: <agent> usage is unknown (<bucket>: <reason>[ — <hint>]; …); launch
admitted WITHOUT known headroom (usage_gate.on_unknown is warn; set it to
"deny" to block)`. The substring `usage is unknown (` followed by
`<bucket>: <reason>` is preserved for the existing assertions. Add a pure helper
`unknown_policy_notes(config, observations)` in `scripts/nogg_usage.py` that
`doctor` calls from a new line beside the `quota_freshness_notes` call in
`scripts/nogg`: for each agent whose current observation is unknown under
`on_unknown == 'warn'` print `NOTE  usage gate: <agent> usage is unknown — launches are admitted
without known headroom (usage_gate.on_unknown=warn); set "deny" to block`;
silent when everything is known or the policy is `deny` or the gate is
disabled. It never raises and never blocks. Update the packed/gate assertions
that grep the old `warning:` prefix if any do. New suite
`scripts/usage-unknown-visibility.test.sh`. A blocking default is explicitly
left to the Product Owner and recorded as a Non-Goal.

## Risks / Trade-offs

- Honouring a Codex observation until reset can understate usage consumed by
  Codex on another machine; the same blind spot existed within the 600 s
  window and only same-host logs are consulted.
- Task 003 and 004 both touch the unknown-warning surface; the `hint` field is
  the sole contract between them, and 004 reads it with `.get`.
