#!/usr/bin/env bash
# TASK-AGENT-010: the task-reference label is a contract.
#
# `scripts/specforge materialize <change>` MUST set both `openspec:change:<name>`
# and `openspec:task:<TASK-ID>` on every Bead it creates, and each
# `openspec:task:<TASK-ID>` MUST resolve to exactly one `- [ ]` / `- [x]` task
# line in that change's tasks.md. That label is what lets the Lead Agent brief a
# specialist with only the referenced task slice, so a regression here silently
# breaks delegation.
#
# Language-neutral: bash + coreutils only, no network, no Beads/Dolt server.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
specforge="$here/specforge"
repo_root="$(cd "$here/.." && pwd)"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# --- a scratch SpecForge checkout with one change and a git repo -----------
root="$work/root"
mkdir -p "$root/.specforge/state" "$root/.specforge/locks" "$root/openspec/changes/demo"
cp "$repo_root/.specforge/config.json" "$root/.specforge/config.json"
cat >"$root/openspec/changes/demo/tasks.md" <<'MD'
# Tasks

- [ ] TASK-DEMO-001 Do the first demo thing
- [ ] TASK-DEMO-002 Do the second demo thing
- [x] TASK-DEMO-003 Already-done demo thing
MD
printf '# Execution log\n' >"$root/openspec/changes/demo/execution-log.md"
git -C "$root" init -q
git -C "$root" config user.email test@example.com
git -C "$root" config user.name "SpecForge Test"
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

export SPECFORGE_ROOT="$root"
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

"$specforge" materialize demo >"$out" 2>&1 \
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
if "$specforge" validate >"$out" 2>&1; then
  bad "validate accepted an unresolvable openspec:task label"
else
  grep -qF 'maps missing task TASK-DEMO-404' "$out" \
    && ok "validate reports a Bead whose openspec:task label resolves to nothing" \
    || { bad "validate failed but not with the expected message"; cat "$out"; }
fi

unset SPECFORGE_ROOT BD_FIXTURE BD_CREATE_LOG

if [[ $fail -ne 0 ]]; then echo "materialize label-contract checks failed" >&2; exit 1; fi
echo "all materialize label-contract checks passed"
