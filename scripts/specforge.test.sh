#!/usr/bin/env bash
# Focused checks for `scripts/specforge`.
#
# `discoveries` (TASK-BOUNDARY-002, TASK-SYNC-005/006): no discoveries,
# blocked-first ordering, ID/status/title/note surfaced, missing note tolerated,
# the `discovery` label alone selects issues, closed discoveries are surfaced,
# and an acknowledged discovery stops being surfaced.
#
# `sync` / `materialize` (TASK-SYNC-002/003/004/011/012): a closed mapped Bead
# is mirrored exactly once with enriched execution-log evidence, a second run is
# a no-op, and re-running `materialize` over closed Beads creates nothing.
#
# `sync` failure records (TASK-SYNC-007/008/009): transient vs permanent
# classification, bounded retry metadata, JSONL failure log, doctor reporting,
# and a successful sync clearing the record.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
specforge="$here/specforge"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
trap 'rm -f "$out"; rm -rf "$work"' EXIT
out=$(mktemp)

# A `bd` stub: `list --label discovery --json` and `show <id> --json` read
# fixture files from $BD_STUB_DIR; everything else is an error.
mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "list" ]]; then
  cat "$BD_STUB_DIR/discoveries.json"
  exit 0
fi
if [[ "${1:-}" == "show" ]]; then
  f="$BD_STUB_DIR/show-$2.json"
  if [[ -f "$f" ]]; then cat "$f"; else echo '[]'; fi
  exit 0
fi
echo "unexpected bd call: $*" >&2
exit 1
STUB
chmod +x "$work/bin/bd"
export PATH="$work/bin:$PATH"

fail=0
check() { # check <description> <expected-substring>
  if grep -qF -- "$2" "$out"; then echo "ok   - $1"; else
    echo "FAIL - $1 (missing: $2)"; cat "$out"; fail=1; fi
}
refute() { # refute <description> <substring-that-must-be-absent>
  if grep -qF -- "$2" "$out"; then echo "FAIL - $1 (present: $2)"; fail=1; else
    echo "ok   - $1"; fi
}

# --- Scenario: no pending discoveries ---------------------------------------
export BD_STUB_DIR="$work/none"; mkdir -p "$BD_STUB_DIR"
printf '[]\n' >"$BD_STUB_DIR/discoveries.json"
"$specforge" discoveries >"$out" 2>&1
check "no discoveries: friendly line" "no pending discoveries"

# --- Scenario: mixed discoveries, blocked first, note surfaced --------------
export BD_STUB_DIR="$work/mixed"; mkdir -p "$BD_STUB_DIR"
cat >"$BD_STUB_DIR/discoveries.json" <<'JSON'
[
  {"id": "SPEC-aaa", "status": "open", "title": "Non-blocking finding",
   "labels": ["openspec:task:TASK-X", "discovery"]},
  {"id": "SPEC-bbb", "status": "blocked", "title": "Blocking finding",
   "labels": ["discovery"]},
  {"id": "SPEC-ccc", "status": "in_progress", "title": "No note here",
   "labels": ["discovery"]}
]
JSON
printf '[{"id":"SPEC-aaa","notes":"Config drift found; see logs. Suggest a follow-up task."}]\n' >"$BD_STUB_DIR/show-SPEC-aaa.json"
printf '[{"id":"SPEC-bbb","notes":"Upstream API renamed; task cannot finish as specified."}]\n' >"$BD_STUB_DIR/show-SPEC-bbb.json"
printf '[{"id":"SPEC-ccc","notes":""}]\n' >"$BD_STUB_DIR/show-SPEC-ccc.json"
"$specforge" discoveries >"$out" 2>&1

check "mixed: count and blocking summary" "3 pending discoveries (1 blocking)"
check "mixed: blocked issue id + status + title" "[blocked] SPEC-bbb  Blocking finding"
check "mixed: open issue rendered" "[open] SPEC-aaa  Non-blocking finding"
check "mixed: human-readable note surfaced" "Upstream API renamed; task cannot finish as specified."
check "mixed: missing note tolerated" "(no human-readable note recorded)"

# blocked line must appear before the open line
blocked_ln=$(grep -n "SPEC-bbb  Blocking finding" "$out" | head -1 | cut -d: -f1)
open_ln=$(grep -n "SPEC-aaa  Non-blocking finding" "$out" | head -1 | cut -d: -f1)
if [[ "$blocked_ln" -lt "$open_ln" ]]; then echo "ok   - mixed: blocked listed before non-blocking"; else
  echo "FAIL - mixed: blocked not prioritised ($blocked_ln vs $open_ln)"; fail=1; fi

# --- Scenario: label is the only selector ----------------------------------
export BD_STUB_DIR="$work/labelonly"; mkdir -p "$BD_STUB_DIR"
cat >"$BD_STUB_DIR/discoveries.json" <<'JSON'
[
  {"id": "SPEC-ddd", "status": "open", "title": "Labelled", "labels": ["discovery"]},
  {"id": "SPEC-eee", "status": "open", "title": "Not labelled", "labels": ["other"]}
]
JSON
printf '[{"id":"SPEC-ddd","notes":"prose"}]\n' >"$BD_STUB_DIR/show-SPEC-ddd.json"
"$specforge" discoveries >"$out" 2>&1
check "label-only: labelled issue shown" "SPEC-ddd  Labelled"
refute "label-only: unlabelled issue skipped" "SPEC-eee"

# --- Scenario: a closed, unreviewed discovery is still surfaced -------------
export BD_STUB_DIR="$work/closeddisc"; mkdir -p "$BD_STUB_DIR"
cat >"$BD_STUB_DIR/discoveries.json" <<'JSON'
[
  {"id": "SPEC-op1", "status": "open", "title": "Open finding", "labels": ["discovery"]},
  {"id": "SPEC-cl1", "status": "closed", "title": "Closed before review", "labels": ["discovery"]}
]
JSON
printf '[{"id":"SPEC-op1","notes":"open prose"}]\n' >"$BD_STUB_DIR/show-SPEC-op1.json"
printf '[{"id":"SPEC-cl1","notes":"closed prose that must not be lost"}]\n' >"$BD_STUB_DIR/show-SPEC-cl1.json"
"$specforge" discoveries >"$out" 2>&1
check "closed-disc: closed discovery listed" "[closed] SPEC-cl1  Closed before review"
check "closed-disc: closed discovery marked awaiting review" "(closed — awaiting review)"
check "closed-disc: closed discovery note preserved" "closed prose that must not be lost"
# open sorts before closed
op_ln=$(grep -n "SPEC-op1  Open finding" "$out" | head -1 | cut -d: -f1)
cl_ln=$(grep -n "SPEC-cl1  Closed before review" "$out" | head -1 | cut -d: -f1)
if [[ "$op_ln" -lt "$cl_ln" ]]; then echo "ok   - closed-disc: open listed before closed"; else
  echo "FAIL - closed-disc: closed not sorted after open ($op_ln vs $cl_ln)"; fail=1; fi

# --- Scenario: acknowledging a discovery stops it being surfaced -----------
ackroot="$work/ackroot"; mkdir -p "$ackroot/.specforge/state"
cp "$repo_root/.specforge/config.json" "$ackroot/.specforge/config.json"
export SPECFORGE_ROOT="$ackroot"
"$specforge" discoveries >"$out" 2>&1
check "ack: closed discovery listed before acknowledgement" "SPEC-cl1  Closed before review"
"$specforge" discoveries --ack SPEC-cl1 >"$out" 2>&1
check "ack: acknowledgement confirmed" "acknowledged 1 discovery Bead(s): SPEC-cl1"
[[ -f "$ackroot/.specforge/state/acknowledged-discoveries.json" ]] \
  && echo "ok   - ack: ledger written under .specforge/state/" \
  || { echo "FAIL - ack: ledger not written"; fail=1; }
"$specforge" discoveries >"$out" 2>&1
refute "ack: acknowledged discovery no longer listed" "SPEC-cl1"
check "ack: unacknowledged discovery still listed" "SPEC-op1  Open finding"
unset SPECFORGE_ROOT

# ===========================================================================
# sync / materialize scenarios: scratch repo pointed at by SPECFORGE_ROOT
# ===========================================================================

# make_root <dir> — a minimal SpecForge checkout with one change and a git repo.
make_root() {
  local r="$1"
  mkdir -p "$r/.specforge/state" "$r/.specforge/locks" "$r/openspec/changes/demo"
  cp "$repo_root/.specforge/config.json" "$r/.specforge/config.json"
  cat >"$r/openspec/changes/demo/tasks.md" <<'MD'
# Tasks

- [ ] TASK-DEMO-001 Do the first demo thing
- [ ] TASK-DEMO-002 Do the second demo thing
MD
  printf '# Execution log\n' >"$r/openspec/changes/demo/execution-log.md"
  git -C "$r" init -q
  git -C "$r" config user.email test@example.com
  git -C "$r" config user.name "SpecForge Test"
  git -C "$r" add -A && git -C "$r" commit -q -m "chore: scratch root [SPEC-000]"
}

# A dispatching `bd` stub. `list` prints $BD_FIXTURE; `show` reads
# $BD_STUB_DIR/show-<id>.json; `create` appends to $BD_CREATE_LOG.
install_bd_stub() {
  cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)  cat "$BD_FIXTURE" ;;
  show)  f="${BD_STUB_DIR:-/nonexistent}/show-${2:-}.json"
         if [[ -f "$f" ]]; then cat "$f"; else echo '[]'; fi ;;
  create) printf '%s\n' "$*" >>"${BD_CREATE_LOG:-/dev/null}"; echo "created stub issue" ;;
  *) echo "unexpected bd call: $*" >&2; exit 1 ;;
esac
STUB
  chmod +x "$work/bin/bd"
}
install_bd_stub

count() { grep -cF -- "$2" "$1" || true; }

# --- Scenario: a closed mapped Bead is mirrored exactly once ----------------
root="$work/sync-once"; make_root "$root"
git -C "$root" commit -q --allow-empty -m "feat(demo): first demo thing [SPEC-d01]"
sha_d01="$(git -C "$root" rev-parse --short=12 HEAD)"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/sync-once-beads.json"
export BD_STUB_DIR="$work/sync-once"; mkdir -p "$BD_STUB_DIR"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-d01", "status": "closed",
   "closed_at": "2026-09-01T10:00:00Z", "updated_at": "2026-09-01T10:00:00Z",
   "notes": "commit abc1234; implemented the first demo thing",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON

"$specforge" sync >"$out" 2>&1 || { echo "FAIL - sync-once: first sync errored"; cat "$out"; fail=1; }
log="$root/openspec/changes/demo/execution-log.md"
tasks="$root/openspec/changes/demo/tasks.md"
[[ "$(count "$log" '<!-- specforge:SPEC-d01:')" == "1" ]] \
  && echo "ok   - sync-once: exactly one execution-log event key" \
  || { echo "FAIL - sync-once: event key count $(count "$log" '<!-- specforge:SPEC-d01:')"; cat "$log"; fail=1; }
grep -qF -- '- [x] TASK-DEMO-001' "$tasks" \
  && echo "ok   - sync-once: task checkbox flipped" \
  || { echo "FAIL - sync-once: checkbox not flipped"; cat "$tasks"; fail=1; }
grep -qF -- 'Bead closed at 2026-09-01T10:00:00Z' "$log" \
  && echo "ok   - sync-once: entry records the closure timestamp" \
  || { echo "FAIL - sync-once: closure timestamp missing"; cat "$log"; fail=1; }
grep -qF -- 'implemented the first demo thing' "$log" \
  && echo "ok   - sync-once: Bead note preserved verbatim in the entry" \
  || { echo "FAIL - sync-once: Bead note not in entry"; cat "$log"; fail=1; }
grep -qF -- "$sha_d01" "$log" \
  && echo "ok   - sync-once: entry lists the commit found by git-log token scan" \
  || { echo "FAIL - sync-once: git-log commit ref missing ($sha_d01)"; cat "$log"; fail=1; }
grep -qF -- 'abc1234' "$log" \
  && echo "ok   - sync-once: entry lists the SHA extracted from the Bead note" \
  || { echo "FAIL - sync-once: note SHA missing"; cat "$log"; fail=1; }

# second run: no diff
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - sync-once: second sync errored"; cat "$out"; fail=1; }
grep -qF "sync: no changes" "$out" \
  && echo "ok   - sync-once: second run reports no changes" \
  || { echo "FAIL - sync-once: second run not a no-op"; cat "$out"; fail=1; }
[[ "$(count "$log" '<!-- specforge:SPEC-d01:')" == "1" ]] \
  && echo "ok   - sync-once: still exactly one event key after re-run" \
  || { echo "FAIL - sync-once: duplicate event key after re-run"; cat "$log"; fail=1; }
[[ "$(count "$tasks" '- [x] TASK-DEMO-001')" == "1" ]] \
  && echo "ok   - sync-once: still exactly one checked task after re-run" \
  || { echo "FAIL - sync-once: checkbox changed on re-run"; fail=1; }
unset SPECFORGE_ROOT

# --- Scenario: closed Bead with no note and no traceable commit ------------
root="$work/sync-bare"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/sync-bare-beads.json"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-d09", "status": "closed", "closed_at": "2026-09-02T09:00:00Z",
   "notes": "",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-002"]}
]
JSON
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - sync-bare: sync errored"; cat "$out"; fail=1; }
log="$root/openspec/changes/demo/execution-log.md"
grep -qF -- 'implementation commits: none found' "$log" \
  && echo "ok   - sync-bare: entry states no commit reference was found" \
  || { echo "FAIL - sync-bare: missing 'none found'"; cat "$log"; fail=1; }
grep -qF -- 'Bead note: (none recorded)' "$log" \
  && echo "ok   - sync-bare: entry written even with an empty note" \
  || { echo "FAIL - sync-bare: missing empty-note marker"; cat "$log"; fail=1; }
grep -qF -- '- [x] TASK-DEMO-002' "$root/openspec/changes/demo/tasks.md" \
  && echo "ok   - sync-bare: task checkbox still flipped" \
  || { echo "FAIL - sync-bare: checkbox not flipped"; fail=1; }
unset SPECFORGE_ROOT

# --- Scenario: re-running materialize over closed Beads creates nothing ----
root="$work/mat-idem"; make_root "$root"
sed -i 's/- \[ \] TASK-DEMO-001/- [x] TASK-DEMO-001/' "$root/openspec/changes/demo/tasks.md"
git -C "$root" commit -qam "chore: pre-check demo-001 [SPEC-000]"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/mat-idem-beads.json"
export BD_CREATE_LOG="$work/mat-idem-create.log"; : >"$BD_CREATE_LOG"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-d01", "status": "closed", "closed_at": "2026-09-01T10:00:00Z",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]},
  {"id": "SPEC-d02", "status": "open",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-002"]}
]
JSON
"$specforge" materialize demo >"$out" 2>&1 || { echo "FAIL - mat-idem: materialize errored"; cat "$out"; fail=1; }
[[ -s "$BD_CREATE_LOG" ]] \
  && { echo "FAIL - mat-idem: materialize created a Bead"; cat "$BD_CREATE_LOG"; fail=1; } \
  || echo "ok   - mat-idem: re-materialize over a closed mapped Bead creates nothing"
grep -qF 'already materialized TASK-DEMO-001' "$out" \
  && echo "ok   - mat-idem: the closed Bead's task counts as materialized" \
  || { echo "FAIL - mat-idem: closed task not recognised"; cat "$out"; fail=1; }
unset SPECFORGE_ROOT BD_CREATE_LOG

# --- Scenario: a permanent (audit) failure is recorded, not retried --------
root="$work/fail-perm"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/fail-perm-beads.json"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-x01", "status": "open",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-404"]}
]
JSON
rec="$root/.specforge/state/sync-failure.json"
"$specforge" sync >"$out" 2>&1 && { echo "FAIL - fail-perm: sync should have failed"; fail=1; }
[[ -f "$rec" ]] \
  && echo "ok   - fail-perm: active failure record written" \
  || { echo "FAIL - fail-perm: no failure record"; fail=1; }
grep -qF '"classification": "permanent"' "$rec" \
  && echo "ok   - fail-perm: classified permanent" \
  || { echo "FAIL - fail-perm: wrong classification"; cat "$rec"; fail=1; }
grep -qF '"next_retry_after": null' "$rec" \
  && echo "ok   - fail-perm: no automatic retry scheduled" \
  || { echo "FAIL - fail-perm: retry was scheduled"; cat "$rec"; fail=1; }
unset SPECFORGE_ROOT

# --- Scenario: a transient (lock) failure records retry metadata -----------
root="$work/fail-trans"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/fail-trans-beads.json"
printf '[]\n' >"$BD_FIXTURE"
held="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
printf '{"pid": 999999, "host": "ghost", "created_at": "%s"}\n' "$held" \
  >"$root/.specforge/locks/sync.lock"
rec="$root/.specforge/state/sync-failure.json"
"$specforge" sync >"$out" 2>&1 && { echo "FAIL - fail-trans: sync should have failed on lock"; fail=1; }
grep -qF '"classification": "transient"' "$rec" \
  && echo "ok   - fail-trans: classified transient" \
  || { echo "FAIL - fail-trans: wrong classification"; cat "$rec"; fail=1; }
grep -qE '"attempts": 1' "$rec" && grep -qE '"max_attempts": [0-9]' "$rec" \
  && echo "ok   - fail-trans: attempt count and cap recorded" \
  || { echo "FAIL - fail-trans: missing attempt metadata"; cat "$rec"; fail=1; }
grep -qE '"next_retry_after": "[0-9]' "$rec" \
  && echo "ok   - fail-trans: next retry time scheduled" \
  || { echo "FAIL - fail-trans: no next retry time"; cat "$rec"; fail=1; }
# a second failure increments attempts
"$specforge" sync >"$out" 2>&1 || true
grep -qF '"attempts": 2' "$rec" \
  && echo "ok   - fail-trans: consecutive failure increments attempts" \
  || { echo "FAIL - fail-trans: attempts did not increment"; cat "$rec"; fail=1; }
jsonl="$root/.specforge/state/sync-failures.jsonl"
[[ "$(count "$jsonl" '"event_time"')" == "2" ]] \
  && echo "ok   - fail-trans: every failure appended to the JSONL log" \
  || { echo "FAIL - fail-trans: JSONL log line count $(count "$jsonl" '"event_time"')"; cat "$jsonl"; fail=1; }
"$specforge" doctor >"$out" 2>&1 || true
grep -qF 'last sync failed (transient)' "$out" \
  && grep -qE 'attempt 2/[0-9]' "$out" \
  && echo "ok   - fail-trans: doctor reports classification, attempts, and next retry" \
  || { echo "FAIL - fail-trans: doctor did not report the failure record"; cat "$out"; fail=1; }
# retries stop at the attempt cap (sync_max_attempts = 5)
for _ in 1 2 3 4 5; do "$specforge" sync >"$out" 2>&1 || true; done
grep -qF '"next_retry_after": null' "$rec" \
  && echo "ok   - fail-trans: no retry scheduled once the attempt cap is reached" \
  || { echo "FAIL - fail-trans: retry still scheduled past the cap"; cat "$rec"; fail=1; }

# --- Scenario: a successful sync clears the failure record -----------------
rm -f "$root/.specforge/locks/sync.lock"
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - clear: recovery sync errored"; cat "$out"; fail=1; }
[[ ! -f "$rec" ]] \
  && echo "ok   - clear: successful sync removed the active failure record" \
  || { echo "FAIL - clear: failure record not cleared"; cat "$rec"; fail=1; }
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: a completed change is archived without breaking validate / sync
# (TASK-HY-003). The fixture is built entirely inside the SPECFORGE_ROOT
# scratch repo — never the real openspec/.
# ===========================================================================
root="$work/archived"; make_root "$root"
arc="$root/openspec/changes/archive/2026-01-01-archived-demo"
mkdir -p "$arc"
cat >"$arc/tasks.md" <<'MD'
# Tasks

- [x] TASK-ARC-001 Do the archived thing
- [x] TASK-ARC-002 Do the other archived thing
- [x] TASK-DEMO-001 An archived task deliberately re-using a live task ID
MD
printf '# Execution log\n\n- SPEC-a01 closed for TASK-ARC-001.\n' >"$arc/execution-log.md"
# demo/tasks.md already carries a live TASK-DEMO-001; the archived tasks.md above
# re-uses that ID. That live/archived pair must not read as a duplicate.
git -C "$root" add -A && git -C "$root" commit -q -m "chore: archived fixture [SPEC-000]"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/archived-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-a01", "status": "closed", "closed_at": "2026-01-01T10:00:00Z",
   "notes": "commit deadbee; archived work",
   "labels": ["openspec:change:archived-demo", "openspec:task:TASK-ARC-001"]},
  {"id": "SPEC-a02", "status": "closed", "closed_at": "2026-01-01T11:00:00Z",
   "notes": "",
   "labels": ["openspec:change:archived-demo", "openspec:task:TASK-ARC-002"]}
]
JSON

# `validate` routes through doctor(), which also checks tool availability — a
# missing `dolt` (as on a CI runner) makes it print `FAIL  dolt` and exit 1.
# That is unrelated to what this test proves, so assert on the audit/mapping
# problem strings only, never the exit code or the bare "FAIL " prefix.
"$specforge" validate >"$out" 2>&1 || true
refute "archived: no 'maps missing task' for the archived Bead" "maps missing task"
refute "archived: no 'incomplete OpenSpec labels' for the archived Bead" "incomplete OpenSpec labels"
refute "archived: no 'change label disagrees' for the archived Bead" "change label disagrees"
refute "archived: no 'has no closed Bead' for the archived task"      "has no closed Bead"
refute "archived: a live/archived shared task ID is not a duplicate"  "duplicate task IDs"

"$specforge" sync >"$out" 2>&1 || { echo "FAIL - archived: sync errored"; cat "$out"; fail=1; }
check "archived: sync reports no changes" "sync: no changes"
[[ ! -d "$root/openspec/changes/archived-demo" ]] \
  && echo "ok   - archived: sync did not resurrect a live change directory" \
  || { echo "FAIL - archived: sync created openspec/changes/archived-demo"; fail=1; }
[[ "$(count "$arc/tasks.md" '- [x] TASK-ARC-001')" == "1" && "$(count "$arc/tasks.md" '- [ ]')" == "0" ]] \
  && echo "ok   - archived: the frozen archived tasks.md was not rewritten" \
  || { echo "FAIL - archived: archived tasks.md changed"; cat "$arc/tasks.md"; fail=1; }
git -C "$root" diff --quiet \
  && echo "ok   - archived: sync made no commit and left the tree clean" \
  || { echo "FAIL - archived: sync dirtied the tree"; git -C "$root" status --porcelain; fail=1; }

"$specforge" materialize archived-demo >"$out" 2>&1 \
  && { echo "FAIL - archived: materialize acted on an archived change"; cat "$out"; fail=1; } \
  || echo "ok   - archived: materialize refuses an archived change (no live tasks)"
unset SPECFORGE_ROOT BD_STUB_DIR

# ===========================================================================
# sync --now (TASK-CMD-008): the on-demand alias behind /sync-now
# ===========================================================================

# --- Scenario: no daemon, no lock — runs one pass directly -----------------
root="$work/now-direct"; make_root "$root"
git -C "$root" commit -q --allow-empty -m "feat(demo): now direct [SPEC-n01]"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/now-direct-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-n01", "status": "closed", "closed_at": "2026-09-02T10:00:00Z",
   "notes": "did the thing",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
"$specforge" sync --now >"$out" 2>&1 || { echo "FAIL - now-direct: sync --now errored"; cat "$out"; fail=1; }
grep -qF -- '- [x] TASK-DEMO-001' "$root/openspec/changes/demo/tasks.md" \
  && echo "ok   - now-direct: sync --now ran a pass and flipped the checkbox" \
  || { echo "FAIL - now-direct: pass did not run"; cat "$out"; fail=1; }
unset SPECFORGE_ROOT BD_STUB_DIR

# --- Scenario: sync lock held by the timer — report, do not retry ----------
root="$work/now-locked"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/now-locked-beads.json"; printf '[]\n' >"$BD_FIXTURE"
held="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
printf '{"pid": 999999, "host": "timer-host", "created_at": "%s"}\n' "$held" \
  >"$root/.specforge/locks/sync.lock"
"$specforge" sync --now >"$out" 2>&1 || { echo "FAIL - now-locked: sync --now should exit 0 on contention"; cat "$out"; fail=1; }
check "now-locked: contention reported with the holder" "sync lock held by timer-host pid 999999"
check "now-locked: does not retry" "not retrying"
[[ ! -f "$root/.specforge/state/sync-failure.json" ]] \
  && echo "ok   - now-locked: no failure record written for a held lock" \
  || { echo "FAIL - now-locked: spurious failure record"; cat "$root/.specforge/state/sync-failure.json"; fail=1; }
unset SPECFORGE_ROOT

# --- Scenario: a stale PID file falls through to a direct pass -------------
root="$work/now-stalepid"; make_root "$root"
git -C "$root" commit -q --allow-empty -m "feat(demo): stale pid [SPEC-n02]"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/now-stalepid-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-n02", "status": "closed", "closed_at": "2026-09-02T11:00:00Z",
   "notes": "",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-002"]}
]
JSON
printf '999999\n' >"$root/.specforge/state/sync.pid"
"$specforge" sync --now >"$out" 2>&1 || { echo "FAIL - now-stalepid: sync --now errored"; cat "$out"; fail=1; }
grep -qF -- '- [x] TASK-DEMO-002' "$root/openspec/changes/demo/tasks.md" \
  && echo "ok   - now-stalepid: dead PID ignored, direct pass ran" \
  || { echo "FAIL - now-stalepid: pass did not run"; cat "$out"; fail=1; }
unset SPECFORGE_ROOT BD_STUB_DIR

# --- Scenario: a live PID file is signalled, no pass is run ---------------
root="$work/now-daemon"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/now-daemon-beads.json"; printf '[]\n' >"$BD_FIXTURE"
sleep 30 &
daemon_pid=$!
disown "$daemon_pid" 2>/dev/null || true   # silence job-control notice when it is signalled
printf '%s\n' "$daemon_pid" >"$root/.specforge/state/sync.pid"
"$specforge" sync --now >"$out" 2>&1 || { echo "FAIL - now-daemon: sync --now errored"; cat "$out"; fail=1; }
check "now-daemon: reports signalling the live daemon PID" "signalled sync daemon pid $daemon_pid"
kill "$daemon_pid" 2>/dev/null || true
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: a fresh install starts with the OpenSpec write boundary closed
# (TASK-TWB-002). doctor bootstraps the sentinel once, only when nothing has
# toggled the boundary yet; plan-begin / plan-end toggle it thereafter.
# ===========================================================================
root="$work/twb-bootstrap"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/twb-bootstrap-beads.json"; printf '[]\n' >"$BD_FIXTURE"
sentinel="$root/.specforge/locks/openspec.readonly"
[[ ! -e "$sentinel" ]] || { echo "FAIL - twb-bootstrap: sentinel present before doctor"; fail=1; }
"$specforge" doctor >"$out" 2>&1 || true
[[ -f "$sentinel" ]] \
  && echo "ok   - twb-bootstrap: first doctor run creates the sentinel" \
  || { echo "FAIL - twb-bootstrap: doctor did not create the sentinel"; cat "$out"; fail=1; }
grep -qF '"by": "doctor"' "$sentinel" \
  && echo "ok   - twb-bootstrap: sentinel records who closed the boundary" \
  || { echo "FAIL - twb-bootstrap: sentinel body wrong"; cat "$sentinel"; fail=1; }
before="$(cat "$sentinel")"
"$specforge" doctor >/dev/null 2>&1 || true
[[ "$(cat "$sentinel")" == "$before" ]] \
  && echo "ok   - twb-bootstrap: a second doctor run does not rewrite the sentinel" \
  || { echo "FAIL - twb-bootstrap: doctor rewrote an existing sentinel"; fail=1; }
"$specforge" plan-begin >/dev/null 2>&1
[[ ! -e "$sentinel" ]] \
  && echo "ok   - twb-bootstrap: plan-begin opens the boundary (sentinel removed)" \
  || { echo "FAIL - twb-bootstrap: plan-begin left the sentinel"; fail=1; }
"$specforge" doctor >/dev/null 2>&1 || true
[[ ! -e "$sentinel" ]] \
  && echo "ok   - twb-bootstrap: doctor does not re-close the boundary while planning is active" \
  || { echo "FAIL - twb-bootstrap: doctor recreated the sentinel during a planning session"; fail=1; }
"$specforge" plan-end >/dev/null 2>&1
[[ -f "$sentinel" ]] \
  && echo "ok   - twb-bootstrap: plan-end closes the boundary again" \
  || { echo "FAIL - twb-bootstrap: plan-end did not write the sentinel"; fail=1; }
unset SPECFORGE_ROOT BD_FIXTURE

# ===========================================================================
# Scenario: scripts/install-hooks closes the boundary on a fresh checkout
# (TASK-TWB-002). Runs in a scratch repo so the real .git/hooks is untouched.
# ===========================================================================
root="$work/twb-install"; make_root "$root"
mkdir -p "$root/scripts"
cp -r "$repo_root/scripts/hooks" "$root/scripts/hooks"
cp "$repo_root/scripts/install-hooks" "$root/scripts/install-hooks"
chmod +x "$root/scripts/install-hooks"
git -C "$root" add -A && git -C "$root" commit -q -m "chore: hook sources [SPEC-000]"
( cd "$root" && ./scripts/install-hooks ) >"$out" 2>&1 || { echo "FAIL - twb-install: install-hooks errored"; cat "$out"; fail=1; }
[[ -f "$root/.specforge/locks/openspec.readonly" ]] \
  && echo "ok   - twb-install: install-hooks creates the boundary sentinel" \
  || { echo "FAIL - twb-install: no sentinel after install-hooks"; cat "$out"; fail=1; }
grep -qF '"by": "install-hooks"' "$root/.specforge/locks/openspec.readonly" \
  && echo "ok   - twb-install: sentinel attributes the closure to install-hooks" \
  || { echo "FAIL - twb-install: wrong sentinel body"; fail=1; }

# ===========================================================================
# Scenario: the sentinel does not gate the sync writer or git branch ops
# (TASK-TWB-005). sync() writes openspec/ directly as the `sync` writer; the
# sentinel is advisory to the guards, not a file-mode change.
# ===========================================================================
root="$work/twb-sync"; make_root "$root"
git -C "$root" commit -q --allow-empty -m "feat(demo): the thing [SPEC-s55]"
mkdir -p "$root/.specforge/locks"
printf '{"closed_at":"x","by":"plan-end"}\n' >"$root/.specforge/locks/openspec.readonly"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/twb-sync-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-s55", "status": "closed",
   "closed_at": "2026-09-02T12:00:00Z", "updated_at": "2026-09-02T12:00:00Z",
   "notes": "did the thing",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - twb-sync: sync errored with the sentinel present"; cat "$out"; fail=1; }
log="$root/openspec/changes/demo/execution-log.md"
grep -qF -- '<!-- specforge:SPEC-s55:' "$log" \
  && echo "ok   - twb-sync: sync mirrored the closed Bead while the sentinel was present" \
  || { echo "FAIL - twb-sync: no execution-log entry"; cat "$log"; fail=1; }
grep -qF -- '- [x] TASK-DEMO-001' "$root/openspec/changes/demo/tasks.md" \
  && echo "ok   - twb-sync: task checkbox flipped despite the sentinel" \
  || { echo "FAIL - twb-sync: checkbox not flipped"; fail=1; }
git -C "$root" log -1 --format='%s' | grep -qF 'chore(sync)' \
  && echo "ok   - twb-sync: the sync writer committed as normal" \
  || { echo "FAIL - twb-sync: no sync commit"; git -C "$root" log -1 --format='%s'; fail=1; }
[[ -f "$root/.specforge/locks/openspec.readonly" ]] \
  && echo "ok   - twb-sync: sync left the sentinel in place (it never touches it)" \
  || { echo "FAIL - twb-sync: sync removed the sentinel"; fail=1; }
# git branch operations are unaffected: a branch that differs under openspec/
git -C "$root" checkout -q -b other
printf 'divergent\n' >>"$root/openspec/changes/demo/tasks.md"
git -C "$root" commit -q -am "chore: diverge openspec [SPEC-000]"
git -C "$root" checkout -q master 2>/dev/null || git -C "$root" checkout -q main
git -C "$root" merge -q --no-edit other >"$out" 2>&1 \
  && echo "ok   - twb-sync: git merge across an openspec/ diff succeeds with the sentinel present" \
  || { echo "FAIL - twb-sync: git merge blocked"; cat "$out"; fail=1; }
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR

# ===========================================================================
# Scenario: doctor reports the OpenSpec write boundary state (TASK-TWB-006)
# ===========================================================================
root="$work/twb-doctor"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/twb-doctor-beads.json"; printf '[]\n' >"$BD_FIXTURE"
mkdir -p "$root/.specforge/locks"
"$specforge" doctor >"$out" 2>&1 || true
check "twb-doctor: closed boundary reported as LOCKED" "openspec write boundary: LOCKED"
"$specforge" plan-begin >/dev/null 2>&1
"$specforge" doctor >"$out" 2>&1 || true
check "twb-doctor: active planning session reported as OPEN" "openspec write boundary: OPEN (planning session active"
"$specforge" plan-end >/dev/null 2>&1
printf '{"pid":1,"host":"h","created_at":"2000-01-01T00:00:00+00:00"}\n' \
  >"$root/.specforge/locks/planning.lock"
rm -f "$root/.specforge/locks/openspec.readonly"
"$specforge" doctor >"$out" 2>&1 || true
check "twb-doctor: stale planning lock named as the reason" \
  "LOCKED (stale planning lock present — run plan-end --force)"
"$specforge" doctor >/dev/null 2>&1; rc_doctor=$?
# a stale lock + closed boundary is a NOTE, not a checked failure: exit code is
# whatever the tool-availability checks produce, never reddened by the boundary.
rm -f "$root/.specforge/locks/planning.lock"
unset SPECFORGE_ROOT BD_FIXTURE

# ===========================================================================
# Scenario: the PreToolUse guard tracks the boundary as plan-begin / plan-end
# toggle it (TASK-TWB-008). End-to-end: real plan-begin/plan-end drive the
# sentinel, and the guard binary is invoked exactly as Claude Code invokes it.
# ===========================================================================
guard="$repo_root/scripts/hooks/pre-tool-use-openspec-guard"
root="$work/twb-guard"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/twb-guard-beads.json"; printf '[]\n' >"$BD_FIXTURE"
mkdir -p "$root/.specforge/locks"
run_guard() { # run_guard <file_path> ; sets $grc
  printf '{"tool_input":{"file_path":"%s"}}' "$1" \
    | CLAUDE_PROJECT_DIR="$root" "$guard" >"$work/twb-guard.err" 2>&1
  grc=$?
}

"$specforge" plan-end --force >/dev/null 2>&1   # boundary closed (sentinel present)
run_guard "openspec/changes/demo/spec.md" || true; [[ "$grc" -eq 2 ]] \
  && echo "ok   - twb-guard: guard blocks an openspec/ write while the sentinel is present" \
  || { echo "FAIL - twb-guard: guard allowed a write with the sentinel present (rc=$grc)"; cat "$work/twb-guard.err"; fail=1; }
grep -qF 'sentinel' "$work/twb-guard.err" \
  && echo "ok   - twb-guard: the block names the sentinel" \
  || { echo "FAIL - twb-guard: block reason did not mention the sentinel"; cat "$work/twb-guard.err"; fail=1; }

run_guard "scripts/whatever.sh" || true; [[ "$grc" -eq 0 ]] \
  && echo "ok   - twb-guard: a write outside openspec/ is never touched" \
  || { echo "FAIL - twb-guard: guard blocked a non-openspec write (rc=$grc)"; fail=1; }

"$specforge" plan-begin >/dev/null 2>&1            # boundary open (fresh planning lock, no sentinel)
run_guard "openspec/changes/demo/spec.md" || true; [[ "$grc" -eq 0 ]] \
  && echo "ok   - twb-guard: guard allows an openspec/ write during a fresh planning session" \
  || { echo "FAIL - twb-guard: guard blocked during planning (rc=$grc)"; cat "$work/twb-guard.err"; fail=1; }

"$specforge" plan-end >/dev/null 2>&1              # boundary closed again
run_guard "openspec/changes/demo/spec.md" || true; [[ "$grc" -eq 2 ]] \
  && echo "ok   - twb-guard: plan-end re-closes the boundary for the guard" \
  || { echo "FAIL - twb-guard: guard still allowed after plan-end (rc=$grc)"; fail=1; }

# a stale planning lock does not confer write permission (W6), even without a
# sentinel on disk
rm -f "$root/.specforge/locks/openspec.readonly"
printf '{"pid":1,"host":"h","created_at":"2000-01-01T00:00:00+00:00"}\n' \
  >"$root/.specforge/locks/planning.lock"
run_guard "openspec/changes/demo/spec.md" || true; [[ "$grc" -eq 2 ]] \
  && echo "ok   - twb-guard: guard blocks when the planning lock is stale (W6)" \
  || { echo "FAIL - twb-guard: guard honoured a stale planning lock (rc=$grc)"; cat "$work/twb-guard.err"; fail=1; }
grep -qF 'stale' "$work/twb-guard.err" \
  && echo "ok   - twb-guard: the block names the stale lock" \
  || { echo "FAIL - twb-guard: block reason did not mention staleness"; cat "$work/twb-guard.err"; fail=1; }
rm -f "$root/.specforge/locks/planning.lock"
unset SPECFORGE_ROOT BD_FIXTURE

if [[ $fail -ne 0 ]]; then echo "specforge checks failed" >&2; exit 1; fi
echo "all specforge checks passed"
