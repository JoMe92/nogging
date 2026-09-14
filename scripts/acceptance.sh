#!/usr/bin/env bash
# Nogging end-to-end acceptance harness — the [M] (mechanical) subset of
# docs/acceptance.md, in the same order, printing each step tag as it runs.
#
#   scripts/acceptance.sh              full run — needs a real bd + dolt backend
#   scripts/acceptance.sh --mechanical no backend: stubs bd and dolt, asserts the
#                                     deterministic spine (readiness gap, one
#                                     materialize-create per task, the sync
#                                     round-trip and its idempotency)
#
# It creates a throwaway git repo, installs Nogging from this checkout
# (node bin/cli.js init), opens a planning session, drops in the canned example
# change (scripts/fixtures/acceptance/), validates, materializes, ends the
# planning session, then on a change branch simulates the closure of the first
# task's Bead, syncs twice, runs doctor/audit, and tears the repo down.
#
# Covered [M] runbook steps: 1 2 3 5 7 8 9 11 12 13 15 16.
# The [A] steps (4 real-npx install, 6 authoring, 10 delegation, 14 discovery
# review, 17 report, 18 sign-off) are the human remainder recorded in the report.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

mechanical=0
case "${1:-}" in
  --mechanical) mechanical=1 ;;
  "") ;;
  *) echo "acceptance: unknown argument: $1" >&2; exit 2 ;;
esac

if ! command -v node >/dev/null 2>&1; then
  echo "acceptance: node is required to run the installer" >&2
  exit 1
fi

work=$(mktemp -d)
target="$work/target"
mkdir -p "$target"
trap 'rm -rf "$work"' EXIT

fail=0
step() { echo; echo "--- $1"; }
note() { echo "    $*"; }
die()  { echo "FAIL - $*" >&2; fail=1; }

mode_label=$([[ $mechanical -eq 1 ]] && echo mechanical || echo full)
echo "Nogging acceptance harness — $mode_label mode"
echo "checkout: $root"
echo "throwaway target: $target"

# --- --mechanical: stub bd and dolt on PATH, no backend, no network ---------
BD_FIXTURE="$work/beads.json"
BD_CREATE_LOG="$work/create.log"
if [[ $mechanical -eq 1 ]]; then
  mkdir -p "$work/bin"
  printf '[]\n' >"$BD_FIXTURE"
  : >"$BD_CREATE_LOG"
  export BD_FIXTURE BD_CREATE_LOG
  # Same contract as scripts/nogg.test.sh: `list` prints $BD_FIXTURE,
  # `show` returns an empty record, `create` appends its argv to $BD_CREATE_LOG.
  cat >"$work/bin/bd" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)   cat "$BD_FIXTURE" ;;
  show)   echo '[]' ;;
  create) printf '%s\n' "$*" >>"${BD_CREATE_LOG:-/dev/null}"; echo "created stub issue" ;;
  version|--version) echo "bd stub (acceptance --mechanical)" ;;
  *) echo "unexpected bd call: $*" >&2; exit 1 ;;
esac
STUB
  cat >"$work/bin/dolt" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$work/bin/bd" "$work/bin/dolt"
  export PATH="$work/bin:$PATH"
fi

# ===========================================================================
# 1 [M] — create a throwaway target repository
# ===========================================================================
step "[M] step 1: create a throwaway target repository"
git -C "$target" init -q
git -C "$target" config user.email acceptance@example.invalid
git -C "$target" config user.name "Nogging Acceptance"
[[ -d "$target/.git" ]] || die "step 1: git repo not created"
note "initialised empty repo at $target"

# ===========================================================================
# 2 [M] — install Nogging from the local checkout
# ===========================================================================
step "[M] step 2: install Nogging from the local checkout"
install_args=(init --no-systemd)
[[ $mechanical -eq 1 ]] && install_args+=(--no-beads)
install_out="$work/install.out"
if ( cd "$target" && node "$root/bin/cli.js" "${install_args[@]}" ) >"$install_out" 2>&1; then
  note "node bin/cli.js ${install_args[*]} exited 0"
else
  die "step 2: installer exited non-zero"
  cat "$install_out"
fi
sf="$target/scripts/nogg"
[[ -x "$sf" ]]                              || die "step 2: scripts/nogg not installed executable"
[[ -f "$target/.nogging/config.json" ]]  || die "step 2: .nogging/config.json missing"
# The boundary hooks are installed into .git/hooks only when core.hooksPath is
# not diverted. A full run's `bd init` points core.hooksPath at .beads/hooks
# (the known Beads collision), and the installer then warns instead of writing
# inert hooks — assert that warning fired rather than the file.
hooks_path=$(git -C "$target" config --get core.hooksPath || true)
if [[ -z "$hooks_path" || "$(cd "$target" && cd "$hooks_path" 2>/dev/null && pwd)" == "$target/.git/hooks" ]]; then
  [[ -f "$target/.git/hooks/commit-msg" ]] || die "step 2: boundary hooks not installed into .git/hooks"
else
  grep -q 'core.hooksPath is set to' "$install_out" \
    || die "step 2: core.hooksPath is diverted ($hooks_path) but the installer did not warn"
  note "core.hooksPath diverted to $hooks_path; installer warned (boundary hooks not auto-bound)"
fi

# ===========================================================================
# 3 [M] — assert the readiness verdict
# ===========================================================================
step "[M] step 3: assert the readiness verdict"
verdict=$(grep -E 'Nogging is (ready|installed but not ready)' "$install_out" | tail -1 || true)
note "verdict: ${verdict:-<none>}"
if [[ -z "$verdict" ]]; then
  die "step 3: installer printed no readiness verdict"
elif [[ $mechanical -eq 1 ]]; then
  # No backend: the verdict must not claim ready, and the uninitialized tracker
  # must be the ONLY gap named.
  case "$verdict" in
    *"Nogging is ready"*) die "step 3: verdict claims ready with no backend" ;;
  esac
  gap=${verdict#*"installed but not ready: "}
  expected='uninitialized tracker (run `bd init`)'
  [[ "$gap" == "$expected" ]] \
    || die "step 3: expected the tracker as the only gap ('$expected'), got '$gap'"
else
  case "$verdict" in
    *"Nogging is ready"*) : ;;
    *) die "step 3: full run did not reach 'Nogging is ready'" ;;
  esac
fi

# ===========================================================================
# 5 [M] — open a planning session   (step 4 [A]: real npx install)
# ===========================================================================
step "[M] step 5: open a planning session"
if ( cd "$target" && "$sf" plan-begin ) >"$work/plan-begin.out" 2>&1; then
  grep -q "planning session lock acquired" "$work/plan-begin.out" \
    || die "step 5: plan-begin did not report the lock acquired"
else
  die "step 5: plan-begin exited non-zero"
fi

# ===========================================================================
# 7 [M] — drop in the canned example change  (step 6 [A]: authoring)
# ===========================================================================
step "[M] step 7: drop in the canned example change"
mkdir -p "$target/openspec/changes"
cp -R "$root/scripts/fixtures/acceptance" "$target/openspec/changes/acceptance-example"
for f in proposal.md design.md tasks.md specs/acceptance-example/spec.md; do
  [[ -f "$target/openspec/changes/acceptance-example/$f" ]] || die "step 7: fixture missing $f"
done
# Commit the install + fixture so the tree is clean before sync. Bookkeeping
# only, so the Nogging boundary hooks are bypassed for this one commit.
git -C "$target" -c core.hooksPath=/dev/null add -A
git -C "$target" -c core.hooksPath=/dev/null commit -q -m "chore: install Nogging and the acceptance fixture"
note "fixture at openspec/changes/acceptance-example/"

# ===========================================================================
# 8 [M] — validate the change
# ===========================================================================
step "[M] step 8: validate the change"
if ( cd "$target" && "$sf" validate ) >"$work/validate.out" 2>&1; then
  grep -q '^FAIL' "$work/validate.out" && { die "step 8: validate reported FAIL lines"; cat "$work/validate.out"; } || true
else
  die "step 8: validate exited non-zero"
  cat "$work/validate.out"
fi

# ===========================================================================
# 9 [M] — materialize the example's Beads
# ===========================================================================
step "[M] step 9: materialize the example's Beads"
if ( cd "$target" && "$sf" materialize acceptance-example ) >"$work/materialize.out" 2>&1; then
  note "$(grep -c 'materialized ' "$work/materialize.out" || true) task(s) materialized"
else
  die "step 9: materialize exited non-zero"
  cat "$work/materialize.out"
fi
if [[ $mechanical -eq 1 ]]; then
  # Exactly one `bd create` per task in the example's tasks.md, and the right
  # ones — the fixture has TASK-ACCEPTX-001 and TASK-ACCEPTX-002.
  creates=$(grep -c '^create ' "$BD_CREATE_LOG" || true)
  [[ "$creates" == "2" ]] || die "step 9: expected 2 materialize-create calls, got $creates"
  grep -q 'openspec:task:TASK-ACCEPTX-001' "$BD_CREATE_LOG" || die "step 9: no create for TASK-ACCEPTX-001"
  grep -q 'openspec:task:TASK-ACCEPTX-002' "$BD_CREATE_LOG" || die "step 9: no create for TASK-ACCEPTX-002"
fi

# ===========================================================================
# 11 [M] — close the planning session
# ===========================================================================
# The mechanical sync refuses to mirror while a planning session is open
# (sync-safety / W5) or while HEAD is on a protected branch. The runbook
# therefore ends the planning session and moves onto a change branch before the
# execution / sync round-trip — matching the operating model, where execution
# and the timer-driven sync run only after `plan-end`.
step "[M] step 11: close the planning session"
if ( cd "$target" && "$sf" plan-end ) >"$work/plan-end.out" 2>&1; then
  grep -q "planning session lock released" "$work/plan-end.out" \
    || die "step 11: plan-end did not report the lock released"
else
  die "step 11: plan-end exited non-zero"
fi

# ===========================================================================
# 12 [M] — simulate the closure and run the mechanical sync  (step 10 [A])
# ===========================================================================
step "[M] step 12: simulate the closure and run the mechanical sync"
# Execution work happens on a change branch, per the operating model; the sync
# writer refuses a protected branch (main/develop), so move off the default one.
git -C "$target" checkout -q -b change/acceptance-example
closed_at="2026-01-01T00:00:00Z"
tasks_md="$target/openspec/changes/acceptance-example/tasks.md"
log_md="$target/openspec/changes/acceptance-example/execution-log.md"
if [[ $mechanical -eq 1 ]]; then
  cat >"$BD_FIXTURE" <<JSON
[
  {"id": "SPEC-ax1", "status": "closed",
   "closed_at": "$closed_at", "updated_at": "$closed_at",
   "notes": "acceptance stub: TASK-ACCEPTX-001 echo-note helper done",
   "labels": ["openspec:change:acceptance-example", "openspec:task:TASK-ACCEPTX-001"]}
]
JSON
else
  first=$(cd "$target" && bd list --json --limit 0 2>/dev/null \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s||"[]");const a=j.issues||j;const m=a.find(i=>(i.labels||[]).includes("openspec:task:TASK-ACCEPTX-001"));process.stdout.write(m?(m.id||""):"")})')
  [[ -n "$first" ]] || die "step 12: could not find the Bead for TASK-ACCEPTX-001"
  ( cd "$target" && bd update "$first" --claim >/dev/null 2>&1 && bd close "$first" >/dev/null 2>&1 ) \
    || die "step 12: could not close $first"
fi
if ( cd "$target" && "$sf" sync ) >"$work/sync1.out" 2>&1; then
  note "$(cat "$work/sync1.out")"
else
  die "step 12: first sync exited non-zero"
  cat "$work/sync1.out"
fi
# The first sync flips exactly one "- [ ]" -> "- [x]" ...
checked=$(grep -c '^- \[x\] ' "$tasks_md" || true)
[[ "$checked" == "1" ]] || die "step 12: expected exactly one checked task after sync, got $checked"
grep -q '^- \[x\] TASK-ACCEPTX-001 ' "$tasks_md" || die "step 12: TASK-ACCEPTX-001 was not checked"
grep -q '^- \[ \] TASK-ACCEPTX-002 ' "$tasks_md" || die "step 12: TASK-ACCEPTX-002 must stay unchecked"
# ... and appends exactly one execution-log.md entry for the closed Bead.
[[ -f "$log_md" ]] || die "step 12: execution-log.md was not written"
entries=$(grep -c '^<!-- nogg:' "$log_md" || true)
[[ "$entries" == "1" ]] || die "step 12: expected exactly one execution-log entry, got $entries"
if [[ $mechanical -eq 1 ]]; then
  grep -q '<!-- nogg:SPEC-ax1:' "$log_md" || die "step 12: log entry is not keyed to the closed Bead SPEC-ax1"
fi
grep -q 'closed for TASK-ACCEPTX-001' "$log_md" || die "step 12: log entry does not name TASK-ACCEPTX-001"
# The mirror is a single commit.
git -C "$target" log -1 --format=%s | grep -q '^chore(sync): mirror Beads execution evidence' \
  || die "step 12: sync did not land the mirror commit"

# ===========================================================================
# 13 [M] — assert sync idempotency
# ===========================================================================
step "[M] step 13: assert sync idempotency"
if ( cd "$target" && "$sf" sync ) >"$work/sync2.out" 2>&1; then
  grep -q 'sync: no changes' "$work/sync2.out" || die "step 13: second sync was not a no-op"
  # Scope the diff check to the example change: a real bd backend churns its
  # own .beads/*.jsonl export, which is not what "the example change files have
  # no further modification" is about.
  git -C "$target" diff --quiet -- openspec/changes/acceptance-example \
    || die "step 13: second sync modified the example change files"
  [[ "$(grep -c '^<!-- nogg:' "$log_md" || true)" == "1" ]] \
    || die "step 13: execution-log entry count changed on the second sync"
  [[ "$(grep -c '^- \[x\] ' "$tasks_md" || true)" == "1" ]] \
    || die "step 13: checked-task count changed on the second sync"
else
  die "step 13: second sync exited non-zero"
  cat "$work/sync2.out"
fi

# ===========================================================================
# 15 [M] — doctor and audit are clean   (step 14 [A]: discovery review)
# ===========================================================================
step "[M] step 15: doctor and audit are clean"
if ( cd "$target" && "$sf" doctor ) >"$work/doctor.out" 2>&1; then
  grep -q '^FAIL' "$work/doctor.out" && { die "step 15: doctor reported FAIL lines"; cat "$work/doctor.out"; } || true
else
  die "step 15: doctor exited non-zero"
  cat "$work/doctor.out"
fi
( cd "$target" && "$sf" audit ) >"$work/audit.out" 2>&1 || die "step 15: audit exited non-zero"

# ===========================================================================
# 16 [M] — tear down
# ===========================================================================
step "[M] step 16: tear down"
note "throwaway repo $target is removed on exit"

echo
if [[ $fail -ne 0 ]]; then
  echo "acceptance: FAILED ($mode_label mode)" >&2
  exit 1
fi
echo "acceptance: all [M] steps passed ($mode_label mode)"
echo "covered [M] runbook steps: 1 2 3 5 7 8 9 11 12 13 15 16"
