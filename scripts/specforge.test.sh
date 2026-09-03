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

# --- lint: no test invokes `specforge doctor|validate|audit` unguarded --------
# Those subcommands exit non-zero on a host missing an optional tool (dolt on a
# CI runner), and with `set -e` an unguarded call kills the test with no message
# (SPEC-3wn, then SPEC-v4t / the v1.2.0 CI break). Every call must be `|| true`,
# `|| rc=...`, or the condition of an `if`/`while`.
lint_hits=$(grep -RnE '"\$specforge" (doctor|validate|audit)\b' "$repo_root"/scripts \
  | grep -vE '\|\| (true|rc)|:\s*if ' || true)
if [[ -n "$lint_hits" ]]; then
  echo "FAIL - lint: unguarded specforge doctor/validate/audit in a test:"
  echo "$lint_hits" | sed 's/^/    /'
  exit 1
fi
echo "ok   - lint: every specforge doctor/validate/audit call in a test is guarded"

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
  # `git init` lands on `main`, which is a protected branch for the sync writer.
  # Scratch repos that exercise a real mirror sit on a change branch, matching
  # the operating model; tests that need a protected branch check one out.
  git -C "$r" checkout -q -b work
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
  create) printf '%s\n' "$*" >>"${BD_CREATE_LOG:-/dev/null}"
          if [[ -n "${BD_CREATE_FAIL:-}" && "$*" == *"${BD_CREATE_FAIL}"* ]]; then
            echo "stub bd create: forced failure for ${BD_CREATE_FAIL}" >&2; exit 1
          fi
          echo "created stub issue" ;;
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
[[ ! -f "$root/.specforge/state/materialize-demo.json" ]] \
  && echo "ok   - mat-idem: the materialize journal is deleted on clean completion" \
  || { echo "FAIL - mat-idem: journal left behind after a clean run"; fail=1; }
unset SPECFORGE_ROOT BD_CREATE_LOG

# --- Scenario: an interrupted materialize leaves a resumable journal -------
# (TASK-RIR-006) The journal names planned vs created tasks; recover reads a
# leftover one; a resumed run completes and removes it.
root="$work/mat-journal"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/mat-journal-beads.json"; printf '[]\n' >"$BD_FIXTURE"
export BD_STUB_DIR="$root"
export BD_CREATE_LOG="$work/mat-journal-create.log"; : >"$BD_CREATE_LOG"
export BD_CREATE_FAIL="TASK-DEMO-002"
"$specforge" materialize demo >"$out" 2>&1 \
  && { echo "FAIL - mat-journal: materialize should fail on the forced bd create error"; fail=1; } \
  || echo "ok   - mat-journal: materialize errors out mid-run"
jr="$root/.specforge/state/materialize-demo.json"
[[ -f "$jr" ]] \
  && echo "ok   - mat-journal: a journal is left behind after the interrupted run" \
  || { echo "FAIL - mat-journal: no journal after interruption"; cat "$out"; fail=1; }
grep -qF '"tasks_planned"' "$jr" && grep -qF 'TASK-DEMO-001' "$jr" && grep -qF 'TASK-DEMO-002' "$jr" \
  && echo "ok   - mat-journal: journal records the planned tasks" \
  || { echo "FAIL - mat-journal: journal missing planned tasks"; cat "$jr"; fail=1; }
"$specforge" recover >"$out" 2>&1 || true
check "mat-journal: recover names the task still needing a Bead" "still needs a Bead: TASK-DEMO-002"
# resume — TASK-DEMO-001 now has a Bead, the forced failure is cleared
unset BD_CREATE_FAIL
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-mj1", "status": "open",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
"$specforge" materialize demo >"$out" 2>&1 \
  || { echo "FAIL - mat-journal: resumed materialize errored"; cat "$out"; fail=1; }
grep -qF 'already materialized TASK-DEMO-001' "$out" \
  && grep -qF 'materialized TASK-DEMO-002' "$out" \
  && echo "ok   - mat-journal: the resume creates only the still-missing Bead" \
  || { echo "FAIL - mat-journal: resume did not finish cleanly"; cat "$out"; fail=1; }
[[ ! -f "$jr" ]] \
  && echo "ok   - mat-journal: the journal is removed once every task has a Bead" \
  || { echo "FAIL - mat-journal: journal survived a clean resume"; cat "$jr"; fail=1; }
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR BD_CREATE_LOG

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
# sync-safety (TASK-STS-001..007): the timer-driven sync refuses an unsafe
# repository state and records why; `sync --now` overrides only a protected
# branch. All fixtures live inside the SPECFORGE_ROOT scratch repo — the real
# planning lock and the real .git are never touched.
# ===========================================================================

# --- Scenario: a held fresh planning lock -> skip, no failure, no-op --------
root="$work/sts-planlock"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/sts-planlock-beads.json"; printf '[]\n' >"$BD_FIXTURE"
seed='{"at":"2020-01-01T00:00:00+00:00","branch":"seed-branch"}'
printf '%s\n' "$seed" >"$root/.specforge/state/last-success.json"
held="$(date -u +%Y-%m-%dT%H:%M:%S+00:00)"
printf '{"pid":1,"host":"h","created_at":"%s"}\n' "$held" \
  >"$root/.specforge/locks/planning.lock"
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - sts-planlock: sync exited non-zero"; cat "$out"; fail=1; }
check "sts-planlock: skip reason printed" "sync: skipped (planning session active)"
[[ ! -f "$root/.specforge/state/sync-failure.json" ]] \
  && echo "ok   - sts-planlock: no failure record for a skipped tick" \
  || { echo "FAIL - sts-planlock: failure record written on skip"; fail=1; }
[[ "$(cat "$root/.specforge/state/last-success.json")" == "$seed" ]] \
  && echo "ok   - sts-planlock: last-success.json left untouched" \
  || { echo "FAIL - sts-planlock: last-success.json changed on skip"; cat "$root/.specforge/state/last-success.json"; fail=1; }
grep -qF -- '"reason": "planning session active"' "$root/.specforge/state/last-skip.json" \
  && echo "ok   - sts-planlock: last-skip.json records the reason" \
  || { echo "FAIL - sts-planlock: last-skip.json missing or wrong"; fail=1; }
"$specforge" doctor >"$out" 2>&1 || true
check "sts-planlock: doctor surfaces the stalled mirror" "last sync skipped: planning session active"
rm -f "$root/.specforge/locks/planning.lock"
unset SPECFORGE_ROOT

# --- Scenario: a merge in progress -> skip; sync --now still refuses it -----
root="$work/sts-merge"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/sts-merge-beads.json"; printf '[]\n' >"$BD_FIXTURE"
touch "$root/.git/MERGE_HEAD"
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - sts-merge: sync exited non-zero"; cat "$out"; fail=1; }
check "sts-merge: timer skips a mid-merge" "sync: skipped (merge in progress)"
[[ ! -f "$root/.specforge/state/sync-failure.json" ]] \
  && echo "ok   - sts-merge: no failure record on a mid-merge skip" \
  || { echo "FAIL - sts-merge: failure record on mid-merge skip"; fail=1; }
"$specforge" sync --now >"$out" 2>&1 || { echo "FAIL - sts-merge: sync --now exited non-zero"; cat "$out"; fail=1; }
check "sts-merge: sync --now refuses a mid-merge" "finish that first"
rm -f "$root/.git/MERGE_HEAD"
unset SPECFORGE_ROOT

# --- Scenario: a detached HEAD -> skip -------------------------------------
root="$work/sts-detached"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/sts-detached-beads.json"; printf '[]\n' >"$BD_FIXTURE"
git -C "$root" checkout -q --detach
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - sts-detached: sync exited non-zero"; cat "$out"; fail=1; }
check "sts-detached: timer skips a detached HEAD" "sync: skipped (detached HEAD)"
unset SPECFORGE_ROOT

# --- Scenario: HEAD on develop -> timer skips, sync --now proceeds ---------
root="$work/sts-protected"; make_root "$root"
git -C "$root" checkout -q -b develop
git -C "$root" commit -q --allow-empty -m "feat(demo): protected thing [SPEC-p1]"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/sts-protected-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-p1", "status": "closed", "closed_at": "2026-09-02T10:00:00Z",
   "notes": "did the protected thing",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - sts-protected: timer sync exited non-zero"; cat "$out"; fail=1; }
check "sts-protected: timer skips a protected branch" "sync: skipped (on protected branch develop)"
grep -qF -- '- [ ] TASK-DEMO-001' "$root/openspec/changes/demo/tasks.md" \
  && echo "ok   - sts-protected: the timer skip left the checkbox unflipped" \
  || { echo "FAIL - sts-protected: checkbox flipped on a protected branch"; fail=1; }
"$specforge" sync --now >"$out" 2>&1 || { echo "FAIL - sts-protected: sync --now exited non-zero"; cat "$out"; fail=1; }
grep -qF -- '- [x] TASK-DEMO-001' "$root/openspec/changes/demo/tasks.md" \
  && echo "ok   - sts-protected: sync --now proceeds on a protected branch" \
  || { echo "FAIL - sts-protected: sync --now did not mirror on develop"; cat "$out"; fail=1; }
grep -qF -- '"branch": "develop"' "$root/.specforge/state/last-success.json" \
  && echo "ok   - sts-protected: last-success.json records the develop branch" \
  || { echo "FAIL - sts-protected: branch not recorded"; cat "$root/.specforge/state/last-success.json"; fail=1; }
[[ ! -f "$root/.specforge/state/last-skip.json" ]] \
  && echo "ok   - sts-protected: the successful sync --now cleared last-skip.json" \
  || { echo "FAIL - sts-protected: last-skip.json not cleared by a successful sync"; fail=1; }
unset SPECFORGE_ROOT BD_STUB_DIR

# --- Scenario: the branch changes between runs -> note + recorded branch ---
root="$work/sts-branchnote"; make_root "$root"
git -C "$root" checkout -q -b feat/one
git -C "$root" commit -q --allow-empty -m "feat(demo): one [SPEC-o1]"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/sts-branchnote-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-o1", "status": "closed", "closed_at": "2026-09-02T10:00:00Z",
   "notes": "one", "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - sts-branchnote: first sync errored"; cat "$out"; fail=1; }
grep -qF -- '"branch": "feat/one"' "$root/.specforge/state/last-success.json" \
  && echo "ok   - sts-branchnote: first run records feat/one" \
  || { echo "FAIL - sts-branchnote: feat/one not recorded"; cat "$root/.specforge/state/last-success.json"; fail=1; }
git -C "$root" checkout -q -b feat/two
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-o1", "status": "closed", "closed_at": "2026-09-02T10:00:00Z",
   "notes": "one", "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]},
  {"id": "SPEC-o2", "status": "closed", "closed_at": "2026-09-02T11:00:00Z",
   "notes": "two", "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-002"]}
]
JSON
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - sts-branchnote: second sync errored"; cat "$out"; fail=1; }
check "sts-branchnote: branch-change note printed" "sync: note — mirroring on feat/two (last run was on feat/one)"
grep -qF -- '"branch": "feat/two"' "$root/.specforge/state/last-success.json" \
  && echo "ok   - sts-branchnote: last-success.json branch updated to feat/two" \
  || { echo "FAIL - sts-branchnote: branch not updated"; cat "$root/.specforge/state/last-success.json"; fail=1; }
unset SPECFORGE_ROOT BD_STUB_DIR

# --- Scenario: a skipped tick retries once the reason clears ---------------
root="$work/sts-retry"; make_root "$root"
git -C "$root" commit -q --allow-empty -m "feat(demo): retry thing [SPEC-r1]"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/sts-retry-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-r1", "status": "closed", "closed_at": "2026-09-02T10:00:00Z",
   "notes": "retry", "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
touch "$root/.git/MERGE_HEAD"
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - sts-retry: skipped sync exited non-zero"; cat "$out"; fail=1; }
rm -f "$root/.git/MERGE_HEAD"
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - sts-retry: recovery sync errored"; cat "$out"; fail=1; }
grep -qF -- '- [x] TASK-DEMO-001' "$root/openspec/changes/demo/tasks.md" \
  && echo "ok   - sts-retry: the next tick mirrors once the mid-merge clears" \
  || { echo "FAIL - sts-retry: outstanding closure not mirrored after the reason cleared"; cat "$out"; fail=1; }
[[ ! -f "$root/.specforge/state/last-skip.json" ]] \
  && echo "ok   - sts-retry: last-skip.json cleared by the recovery sync" \
  || { echo "FAIL - sts-retry: last-skip.json not cleared"; fail=1; }
unset SPECFORGE_ROOT BD_STUB_DIR

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
git -C "$root" checkout -q work
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
# a stale lock + closed boundary is a NOTE, not a checked failure: doctor's exit
# code is whatever the tool-availability checks produce (non-zero on a host
# without dolt, e.g. CI) and `set -e` must not see it — hence `|| true`.
"$specforge" doctor >/dev/null 2>&1 || true
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

# ===========================================================================
# Scenario: doctor flags a stale external Codex execpolicy rule (TASK-COB-007)
# A prefix_rule whose pattern names a path that does not resolve under ROOT is
# printed as an INFO line naming the rule and its file, and never as a failure.
# ===========================================================================
root="$work/codex-doctor"; make_root "$root"
mkdir -p "$root/.codex/rules"
cat >"$root/.codex/rules/stale.rules" <<'RULES'
prefix_rule(pattern=["mkdir", "-p", "/srv/repos/some-other-project"], decision="allow")
RULES
cat >"$root/.codex/rules/clean.rules" <<'RULES'
prefix_rule(pattern=["git", "push"], decision="forbidden")
prefix_rule(pattern=["cat", "openspec/changes/demo/tasks.md"], decision="allow")
RULES
export SPECFORGE_ROOT="$root"
"$specforge" doctor >"$out" 2>&1 || true
check "codex-doctor: stale external rule surfaced as INFO" \
  "INFO  stale external Codex rule:"
check "codex-doctor: the INFO line names the offending pattern" \
  "/srv/repos/some-other-project"
check "codex-doctor: the INFO line names the rules file" "stale.rules"
if grep -qF -- 'clean.rules' "$out"; then
  echo "FAIL - codex-doctor: a rule that resolves under ROOT was flagged"; fail=1
else
  echo "ok   - codex-doctor: an in-repo rule path is not flagged"
fi
if grep -E 'FAIL .*Codex rule' "$out" >/dev/null 2>&1; then
  echo "FAIL - codex-doctor: the stale rule was treated as a failure"; fail=1
else
  echo "ok   - codex-doctor: the stale rule is informational, not a failure"
fi
unset SPECFORGE_ROOT

# ===========================================================================
# Scenario: a committed-but-open Bead is a warning, not a problem (TASK-RIR-002)
# validate() reports `LIMBO: <id> committed in <sha> but status=<status>` as a
# warning; doctor prints it as WARN; sync still mirrors a separate closed Bead.
# ===========================================================================
root="$work/rir-limbo"; make_root "$root"
git -C "$root" commit -q --allow-empty -m "feat(demo): limbo thing [SPEC-lmb]"
git -C "$root" commit -q --allow-empty -m "feat(demo): done thing [SPEC-dun]"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/rir-limbo-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-lmb", "status": "in_progress",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]},
  {"id": "SPEC-dun", "status": "closed", "closed_at": "2026-09-02T09:00:00Z",
   "notes": "done", "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-002"]}
]
JSON
"$specforge" validate >"$out" 2>&1 || true
check "rir-limbo: validate reports the LIMBO warning" "LIMBO: SPEC-lmb committed in"
check "rir-limbo: validate marks it as a WARN line" "WARN  LIMBO: SPEC-lmb"
refute "rir-limbo: the LIMBO line is not a FAIL" "FAIL  LIMBO"
"$specforge" doctor >"$out" 2>&1 || true
check "rir-limbo: doctor prints the LIMBO as WARN" "WARN  LIMBO: SPEC-lmb committed in"
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - rir-limbo: sync errored on a limbo Bead"; cat "$out"; fail=1; }
grep -qF -- '- [x] TASK-DEMO-002' "$root/openspec/changes/demo/tasks.md" \
  && echo "ok   - rir-limbo: sync still mirrored the separate closed Bead" \
  || { echo "FAIL - rir-limbo: sync did not mirror the closed Bead"; cat "$out"; fail=1; }
grep -qF -- '- [ ] TASK-DEMO-001' "$root/openspec/changes/demo/tasks.md" \
  && echo "ok   - rir-limbo: the limbo Bead's task stays unchecked" \
  || { echo "FAIL - rir-limbo: limbo task was checked"; fail=1; }
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR

# ===========================================================================
# Scenario: `recover` — the interrupted-run diagnostic (TASK-RIR-003)
# Read-only; exits non-zero on a LIMBO Bead / stale lock / orphan /
# materialized-but-uncommitted change / crashed session, zero on a clean repo.
#
# TASK-RIR-013 checklist coverage:
#   - committed-but-open Bead -> LIMBO, non-zero exit ...... rec-limbo (below)
#   - stale lock .......................................... rec-lock (below)
#   - in_progress Bead with a commit -> resumable ......... rec-resumable (below)
#   - old commitless in_progress claim -> stale ........... rec-stale-claim (below)
#   - mapped Beads + dirty tasks.md -> mat-uncommitted .... rec-matuncommitted (below)
#   - leftover materialize-<change>.json names the task ... rec-journal (below) + mat-journal
#   - clean repo exits zero .............................. rec-clean (below)
#   - validate() LIMBO warning does not redden sync ...... rir-limbo (above)
#   - recover mutates nothing ........................... rec-readonly (below)
# ===========================================================================

# --- clean repo exits zero -------------------------------------------------
root="$work/rec-clean"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/rec-clean-beads.json"; printf '[]\n' >"$BD_FIXTURE"
export BD_STUB_DIR="$root"
"$specforge" recover >"$out" 2>&1 \
  && echo "ok   - rec-clean: recover exits zero on a clean repo" \
  || { echo "FAIL - rec-clean: recover exited non-zero on a clean repo"; cat "$out"; fail=1; }
check "rec-clean: says nothing is in flight" "nothing in flight"
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR

# --- a committed-but-open Bead is LIMBO and exits non-zero ---------------
root="$work/rec-limbo"; make_root "$root"
git -C "$root" commit -q --allow-empty -m "feat(demo): limbo work [SPEC-lim]"
sha_lim="$(git -C "$root" rev-parse --short=12 HEAD)"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/rec-limbo-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-lim", "status": "open",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
"$specforge" recover >"$out" 2>&1 \
  && { echo "FAIL - rec-limbo: recover should exit non-zero"; cat "$out"; fail=1; } \
  || echo "ok   - rec-limbo: recover exits non-zero with a committed-but-open Bead"
check "rec-limbo: lists the LIMBO Bead" "LIMBO: SPEC-lim committed in"
check "rec-limbo: names the commit SHA" "$sha_lim"
check "rec-limbo: attention summary names it" "need attention"
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR

# --- a stale lock exits non-zero ---------------------------------------
root="$work/rec-lock"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/rec-lock-beads.json"; printf '[]\n' >"$BD_FIXTURE"
export BD_STUB_DIR="$root"
printf '{"pid":999999,"host":"ghost","created_at":"2000-01-01T00:00:00+00:00"}\n' \
  >"$root/.specforge/locks/planning.lock"
"$specforge" recover >"$out" 2>&1 \
  && { echo "FAIL - rec-lock: recover should exit non-zero on a stale lock"; cat "$out"; fail=1; } \
  || echo "ok   - rec-lock: recover exits non-zero on a stale lock"
check "rec-lock: reports the stale planning lock" "planning.lock: STALE"
rm -f "$root/.specforge/locks/planning.lock"
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR

# --- an in_progress Bead with a commit classifies resumable ------------
root="$work/rec-resumable"; make_root "$root"
git -C "$root" commit -q --allow-empty -m "feat(demo): resumable work [SPEC-rsm]"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/rec-resumable-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-rsm", "status": "in_progress", "updated_at": "2026-09-03T00:00:00Z",
   "assignee": "someone",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-002"]}
]
JSON
"$specforge" recover >"$out" 2>&1 || true
check "rec-resumable: in_progress Bead with a commit is resumable" "SPEC-rsm [resumable]"
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR

# --- an old in_progress claim with no commit is stale (TASK-RIR-010) --
root="$work/rec-stale-claim"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/rec-stale-claim-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-old", "status": "in_progress", "updated_at": "2020-01-01T00:00:00Z",
   "assignee": "someone",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
grep -q '"claim_stale_seconds"' "$root/.specforge/config.json" \
  && echo "ok   - rec-stale-claim: config carries claim_stale_seconds" \
  || { echo "FAIL - rec-stale-claim: claim_stale_seconds not in config"; fail=1; }
"$specforge" recover >"$out" 2>&1 \
  && echo "ok   - rec-stale-claim: a stale claim alone does not fail recover" \
  || { echo "FAIL - rec-stale-claim: recover exited non-zero for a stale claim only"; cat "$out"; fail=1; }
check "rec-stale-claim: the old claim is labelled stale" "SPEC-old [stale]"
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR

# --- a live change with mapped Beads but a dirty tasks.md --------------
root="$work/rec-matuncommitted"; make_root "$root"
printf '\n<!-- uncommitted edit -->\n' >>"$root/openspec/changes/demo/tasks.md"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/rec-matuncommitted-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-mmm", "status": "open",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
"$specforge" recover >"$out" 2>&1 \
  && { echo "FAIL - rec-matuncommitted: recover should exit non-zero"; cat "$out"; fail=1; } \
  || echo "ok   - rec-matuncommitted: recover exits non-zero for a dirty mapped tasks.md"
check "rec-matuncommitted: names the change and the reason" "demo: tasks.md has uncommitted changes"
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR

# --- a hand-placed leftover materialize journal (crash simulation) -----
# (TASK-RIR-013) distinct from mat-journal's real interrupted run: recover
# reads a journal that a crash left on disk and names the task with no Bead.
root="$work/rec-journal"; make_root "$root"
mkdir -p "$root/.specforge/state"
cat >"$root/.specforge/state/materialize-demo.json" <<'JSON'
{
  "started_at": "2026-09-03T00:00:00+00:00",
  "tasks_planned": ["TASK-DEMO-001", "TASK-DEMO-002"],
  "tasks_created": ["TASK-DEMO-001"]
}
JSON
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/rec-journal-beads.json"; printf '[]\n' >"$BD_FIXTURE"
export BD_STUB_DIR="$root"
"$specforge" recover >"$out" 2>&1 \
  && { echo "FAIL - rec-journal: recover should exit non-zero for a leftover journal"; cat "$out"; fail=1; } \
  || echo "ok   - rec-journal: recover exits non-zero for a leftover materialize journal"
check "rec-journal: names the still-missing task" "still needs a Bead: TASK-DEMO-002"
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR

# --- recover mutates nothing -----------------------------------------
root="$work/rec-readonly"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/rec-readonly-beads.json"
export BD_STUB_DIR="$root"
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-ro1", "status": "in_progress", "updated_at": "2026-09-03T00:00:00Z",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-001"]}
]
JSON
before_state="$(find "$root/.specforge" -type f | sort | xargs cksum 2>/dev/null | cksum)"
before_tree="$(git -C "$root" status --porcelain; git -C "$root" rev-parse HEAD)"
"$specforge" recover >"$out" 2>&1 || true
after_state="$(find "$root/.specforge" -type f | sort | xargs cksum 2>/dev/null | cksum)"
after_tree="$(git -C "$root" status --porcelain; git -C "$root" rev-parse HEAD)"
[[ "$before_state" == "$after_state" ]] \
  && echo "ok   - rec-readonly: recover wrote no file under .specforge/" \
  || { echo "FAIL - rec-readonly: .specforge/ changed"; fail=1; }
[[ "$before_tree" == "$after_tree" ]] \
  && echo "ok   - rec-readonly: recover made no commit and did not touch the tree" \
  || { echo "FAIL - rec-readonly: working tree / HEAD changed"; fail=1; }
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR

# ===========================================================================
# Scenario: doctor runs recover's checks (TASK-RIR-004)
# Plain `doctor` prints a one-line recover summary NOTE and keeps its
# tool-availability exit semantics; `doctor --recover` folds the full report
# and fails when anything needs attention.
# ===========================================================================
root="$work/rir-doctor-recover"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/rir-doctor-recover-beads.json"; printf '[]\n' >"$BD_FIXTURE"
export BD_STUB_DIR="$root"
"$specforge" doctor >"$out" 2>&1 || true
check "rir-doctor-recover: plain doctor prints a recover summary NOTE" "NOTE  recover:"
refute "rir-doctor-recover: plain doctor does not print the RECOVER block" "RECOVER  "
printf '{"pid":999999,"host":"ghost","created_at":"2000-01-01T00:00:00+00:00"}\n' \
  >"$root/.specforge/locks/planning.lock"
"$specforge" doctor >"$out" 2>&1 || true
check "rir-doctor-recover: the summary NOTE names the stale lock" "stale planning.lock"
rc=0; "$specforge" doctor --recover >"$out" 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] \
  && echo "ok   - rir-doctor-recover: doctor --recover exits non-zero when recover flags something" \
  || { echo "FAIL - rir-doctor-recover: doctor --recover should fail on a stale lock"; cat "$out"; fail=1; }
check "rir-doctor-recover: doctor --recover prints the RECOVER report" "RECOVER  Locks"
rm -f "$root/.specforge/locks/planning.lock"
unset SPECFORGE_ROOT BD_FIXTURE BD_STUB_DIR

# ===========================================================================
# Scenario: validate() returns a 4-tuple (TASK-RIR-001)
# (tasks, issues, problems, warnings) — warnings is a list, distinct from
# problems, so `sync()`'s AuditError path stays keyed on `problems` only.
# ===========================================================================
root="$work/rir-arity"; make_root "$root"
export SPECFORGE_ROOT="$root"
export BD_FIXTURE="$work/rir-arity-beads.json"; printf '[]\n' >"$BD_FIXTURE"
arity=$(python3 - "$repo_root/scripts/specforge" <<'PY'
import sys
from importlib.machinery import SourceFileLoader
m = SourceFileLoader("sf_arity", sys.argv[1]).load_module()
r = m.validate()
print(len(r), isinstance(r[2], list), isinstance(r[3], list))
PY
)
[[ "$arity" == "4 True True" ]] \
  && echo "ok   - rir-arity: validate() returns (tasks, issues, problems, warnings)" \
  || { echo "FAIL - rir-arity: validate() arity/shape is '$arity'"; fail=1; }
unset SPECFORGE_ROOT BD_FIXTURE

if [[ $fail -ne 0 ]]; then echo "specforge checks failed" >&2; exit 1; fi
echo "all specforge checks passed"
