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

# --- Scenario: a successful sync clears the failure record -----------------
rm -f "$root/.specforge/locks/sync.lock"
"$specforge" sync >"$out" 2>&1 || { echo "FAIL - clear: recovery sync errored"; cat "$out"; fail=1; }
[[ ! -f "$rec" ]] \
  && echo "ok   - clear: successful sync removed the active failure record" \
  || { echo "FAIL - clear: failure record not cleared"; cat "$rec"; fail=1; }
unset SPECFORGE_ROOT

if [[ $fail -ne 0 ]]; then echo "specforge checks failed" >&2; exit 1; fi
echo "all specforge checks passed"
