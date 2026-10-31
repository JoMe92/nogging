#!/usr/bin/env bash
# TASK-AGENT-010: the task-reference label is a contract.
#
# `scripts/nogg materialize <change>` MUST set both `openspec:change:<name>`
# and `openspec:task:<TASK-ID>` on every Bead it creates, and each
# `openspec:task:<TASK-ID>` MUST resolve to exactly one `- [ ]` / `- [x]` task
# line in that change's tasks.md. That label is what lets the Lead Agent brief a
# specialist with only the referenced task slice, so a regression here silently
# breaks delegation.
#
# Language-neutral: bash + coreutils only, no network, no Beads/Dolt server.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/test-fixture-config.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
nogg="$here/nogg"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# --- a scratch Nogging checkout with one change and a git repo -----------
root="$work/root"
mkdir -p "$root/.nogging/state" "$root/.nogging/locks" "$root/openspec/changes/demo"
copy_host_config "$repo_root/.nogging/config.json" "$root/.nogging/config.json"
cat >"$root/openspec/changes/demo/tasks.md" <<'MD'
# Tasks

- [ ] TASK-DEMO-001 Do the first demo thing
- [ ] TASK-DEMO-002 Do the second demo thing
- [x] TASK-DEMO-003 Already-done demo thing
MD
printf '# Execution log\n' >"$root/openspec/changes/demo/execution-log.md"
git -C "$root" init -q
git -C "$root" config user.email test@example.com
git -C "$root" config user.name "Nogging Test"
git -C "$root" add -A
git -C "$root" commit -q -m "chore: scratch root [SPEC-000]"

# --- a `bd` stub: list -> fixture, create -> append to the create log ------
mkdir -p "$work/bin"
cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)   cat "$BD_FIXTURE" ;;
  show)   echo '[]' ;;
  create) printf '%s\n' "$*" >>"$BD_CREATE_LOG"; echo "created stub issue" ;;
  *) echo "unexpected bd call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$work/bin/bd"
export PATH="$work/bin:$PATH"

export NOGGING_ROOT="$root"
export BD_FIXTURE="$work/beads.json"
export BD_CREATE_LOG="$work/create.log"
: >"$BD_CREATE_LOG"

# TASK-DEMO-003 is checked, so its Bead must already be closed or validate()
# rejects the run. The other two tasks are unmaterialized.
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-d03", "status": "closed", "closed_at": "2026-09-01T10:00:00Z",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-003"]}
]
JSON

"$nogg" materialize demo >"$out" 2>&1 \
  || { bad "materialize demo errored"; cat "$out"; }

# --- 1. one create call per unmaterialized task ---------------------------
created=$(grep -c '^create ' "$BD_CREATE_LOG" || true)
[[ "$created" == "2" ]] \
  && ok "materialize created one Bead per open task (2)" \
  || bad "expected 2 create calls, got $created ($(cat "$BD_CREATE_LOG"))"

grep -qF 'already materialized TASK-DEMO-003' "$out" \
  && ok "the checked task with a closed Bead is not re-created" \
  || bad "closed/checked task TASK-DEMO-003 was not skipped"

tasks_file="$root/openspec/changes/demo/tasks.md"

# --- 2. every created Bead carries both labels, and the task label resolves
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # the labels argument is the token after `--labels`
  labels=$(printf '%s\n' "$line" | sed -n 's/.*--labels \([^ ]*\).*/\1/p')
  title=$(printf '%s\n' "$line" | sed -n 's/.*--title \(TASK-[A-Z0-9-]*\):.*/\1/p')

  case ",$labels," in
    *",openspec:change:demo,"*) ok "$title: openspec:change:demo set" ;;
    *) bad "$title: openspec:change:demo missing (labels: $labels)" ;;
  esac

  task=$(printf '%s\n' "$labels" | tr ',' '\n' | sed -n 's/^openspec:task://p')
  if [[ -z "$task" ]]; then
    bad "$title: no openspec:task:<TASK-ID> label (labels: $labels)"
    continue
  fi
  ok "$title: openspec:task:$task set"

  matches=$(grep -cE "^- \[[ x]\] ${task}( |\$)" "$tasks_file" || true)
  [[ "$matches" == "1" ]] \
    && ok "$title: openspec:task:$task resolves to exactly one task line" \
    || bad "$title: openspec:task:$task resolved to $matches task lines"

  [[ "$task" == "$title" ]] \
    && ok "$title: task label agrees with the created title" \
    || bad "$title: task label $task disagrees with title $title"
done <"$BD_CREATE_LOG"

# --- 3. validate() rejects a Bead whose task label resolves to nothing -----
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-d03", "status": "closed",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-003"]},
  {"id": "SPEC-bad", "status": "open",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-404"]}
]
JSON
if "$nogg" validate >"$out" 2>&1; then
  bad "validate accepted an unresolvable openspec:task label"
else
  grep -qF 'maps missing task TASK-DEMO-404' "$out" \
    && ok "validate reports a Bead whose openspec:task label resolves to nothing" \
    || { bad "validate failed but not with the expected message"; cat "$out"; }
fi

# --- 4. a new task may not demand the full suite --------------------------
# The pure field checks run first; then `validate` and `materialize` on this
# scratch root. The rule lives outside the mapping audit, so `doctor` must stay
# green on the same plan, and a task that already has a Bead only gets a NOTE.
if python3 -B "$here/lib/testing_tasks_test.py" >"$out" 2>&1; then
  ok "the tasks.md field checks pass"
else
  bad "the tasks.md field checks failed"; cat "$out"
fi
mkdir -p "$root/openspec/changes/strict" "$root/openspec/changes/lenient"
cat >"$root/openspec/changes/strict/tasks.md" <<'MD'
# Tasks

- [ ] TASK-STR-001 Demands everything
  Tests: small Scenario "A".
  Check: scripts/test. Branch docs/.
- [ ] TASK-STR-002 Names a suite
  Tests: small Scenario "B".
  Check: scripts/session-dispatch.test.sh. Branch docs/.
MD
cat >"$root/openspec/changes/lenient/tasks.md" <<'MD'
# Tasks

- [ ] TASK-LEN-001 Approved before the rule
  Check: scripts/test. Branch docs/.
- [ ] TASK-LEN-002 Documentation only
  Tests: none (documentation only).
MD
cat >"$BD_FIXTURE" <<'JSON'
[
  {"id": "SPEC-d03", "status": "closed",
   "labels": ["openspec:change:demo", "openspec:task:TASK-DEMO-003"]},
  {"id": "SPEC-len1", "status": "open",
   "labels": ["openspec:change:lenient", "openspec:task:TASK-LEN-001"]},
  {"id": "SPEC-len2", "status": "open",
   "labels": ["openspec:change:lenient", "openspec:task:TASK-LEN-002"]}
]
JSON
rc=0; "$nogg" validate >"$out" 2>&1 || rc=$?
[[ $rc -ne 0 ]] && ok "validate fails on a new task that demands the full suite" \
  || bad "validate accepted a new full-suite Check:"
grep -qF 'FAIL  task format: strict: TASK-STR-001' "$out" \
  && grep -qF '"scripts/test"' "$out" \
  && ok "the failure names the task and quotes the match" \
  || { bad "validate did not name TASK-STR-001 and quote the match"; cat "$out"; }
! grep -qF 'TASK-STR-002 has a Check' "$out" \
  && ok "a named suite is not refused" || bad "a named suite was refused"
grep -qF 'NOTE  task format: lenient: TASK-LEN-001 (already materialized)' "$out" \
  && ok "an approved task with a full-suite Check: gets a NOTE" \
  || { bad "no NOTE for the approved task"; cat "$out"; }
! grep -qF 'FAIL  task format: lenient' "$out" \
  && ok "an approved task is not a FAIL" || bad "an approved task failed validate"
! grep -qF 'TASK-LEN-002' "$out" \
  && ok "a documentation task (Tests: none) gets no NOTE" || bad "unexpected NOTE for TASK-LEN-002"
grep -qF 'NOTE  task format: lenient: TASK-LEN-001 carry no Tests: field' "$out" \
  && ok "a task without Tests: gets a NOTE naming it" || bad "no NOTE for the missing Tests: field"

rc=0; "$nogg" doctor >"$out" 2>&1 || rc=$?
! grep -qF 'FAIL  task format' "$out" \
  && ok "doctor never fails on the task format" || bad "doctor failed on the task format"
grep -qF 'NOTE  task format: strict: TASK-STR-001' "$out" \
  && ok "doctor shows the refusal as a NOTE" || bad "doctor did not show a NOTE for TASK-STR-001"

: >"$BD_CREATE_LOG"
rc=0; "$nogg" materialize strict >"$out" 2>&1 || rc=$?
[[ $rc -ne 0 ]] && grep -qF 'TASK-STR-001' "$out" \
  && ok "materialize refuses a change with a full-suite Check:" \
  || { bad "materialize did not refuse"; cat "$out"; }
[[ ! -s "$BD_CREATE_LOG" ]] \
  && ok "materialize created no Bead, not even for the named-suite task" \
  || bad "materialize created Beads before refusing: $(cat "$BD_CREATE_LOG")"
[[ ! -e "$root/.nogging/state/materialize-strict.json" ]] \
  && ok "materialize wrote no journal" || bad "materialize left a journal"

sed -i 's|Check: scripts/test\. Branch|Check: scripts/session-dispatch.test.sh. Branch|' "$root/openspec/changes/strict/tasks.md"
"$nogg" materialize strict >"$out" 2>&1 \
  && [[ "$(grep -c '^create ' "$BD_CREATE_LOG")" == 2 ]] \
  && ok "materialize creates every Bead once the Check: names suites" \
  || { bad "materialize still refused after the fix"; cat "$out"; }

unset NOGGING_ROOT BD_FIXTURE BD_CREATE_LOG

if [[ $fail -ne 0 ]]; then echo "materialize label-contract checks failed" >&2; exit 1; fi
echo "all materialize label-contract checks passed"
