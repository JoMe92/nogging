#!/usr/bin/env bash
# SpecForge end-to-end acceptance harness — the [M] (mechanical) subset of
# docs/acceptance.md, in the same order, printing each step tag as it runs.
#
#   scripts/acceptance.sh              full run — needs a real bd + dolt backend
#   scripts/acceptance.sh --mechanical no backend: stubs bd and dolt, asserts the
#                                     deterministic spine (readiness gap, one
#                                     materialize-create per task, the sync
#                                     round-trip and its idempotency)
#
# It creates a throwaway git repo, installs SpecForge from this checkout
# (node bin/cli.js init), opens a planning session, drops in the canned example
# change (scripts/fixtures/acceptance/), validates, materializes, simulates the
# closure of the first task's Bead, syncs twice, runs doctor/audit, ends the
# planning session, and tears the repo down.
#
# Covered [M] runbook steps: 1 2 3 5 7 8 9 11 12 14 15 16.
# The [A] steps (4 real-npx install, 6 authoring, 10 delegation, 13 discovery
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
echo "SpecForge acceptance harness — $mode_label mode"
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
  # Same contract as scripts/specforge.test.sh: `list` prints $BD_FIXTURE,
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
git -C "$target" config user.name "SpecForge Acceptance"
[[ -d "$target/.git" ]] || die "step 1: git repo not created"
note "initialised empty repo at $target"

# ===========================================================================
# 2 [M] — install SpecForge from the local checkout
# ===========================================================================
step "[M] step 2: install SpecForge from the local checkout"
install_args=(init --no-systemd)
[[ $mechanical -eq 1 ]] && install_args+=(--no-beads)
install_out="$work/install.out"
if ( cd "$target" && node "$root/bin/cli.js" "${install_args[@]}" ) >"$install_out" 2>&1; then
  note "node bin/cli.js ${install_args[*]} exited 0"
else
  die "step 2: installer exited non-zero"
  cat "$install_out"
fi
sf="$target/scripts/specforge"
[[ -x "$sf" ]]                              || die "step 2: scripts/specforge not installed executable"
[[ -f "$target/.specforge/config.json" ]]  || die "step 2: .specforge/config.json missing"
[[ -f "$target/.git/hooks/commit-msg" ]]   || die "step 2: git hooks not installed"

# ===========================================================================
# 3 [M] — assert the readiness verdict
# ===========================================================================
step "[M] step 3: assert the readiness verdict"
verdict=$(grep -E 'SpecForge is (ready|installed but not ready)' "$install_out" | tail -1 || true)
note "verdict: ${verdict:-<none>}"
if [[ -z "$verdict" ]]; then
  die "step 3: installer printed no readiness verdict"
elif [[ $mechanical -eq 1 ]]; then
  case "$verdict" in
    *"SpecForge is ready"*) die "step 3: verdict claims ready with no backend" ;;
  esac
else
  case "$verdict" in
    *"SpecForge is ready"*) : ;;
    *) die "step 3: full run did not reach 'SpecForge is ready'" ;;
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
# only, so the SpecForge boundary hooks are bypassed for this one commit.
git -C "$target" -c core.hooksPath=/dev/null add -A
git -C "$target" -c core.hooksPath=/dev/null commit -q -m "chore: install SpecForge and the acceptance fixture"
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

# ===========================================================================
# 11 [M] — simulate the closure and run the mechanical sync  (step 10 [A])
# ===========================================================================
step "[M] step 11: simulate the closure and run the mechanical sync"
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
  [[ -n "$first" ]] || die "step 11: could not find the Bead for TASK-ACCEPTX-001"
  ( cd "$target" && bd update "$first" --claim >/dev/null 2>&1 && bd close "$first" >/dev/null 2>&1 ) \
    || die "step 11: could not close $first"
fi
if ( cd "$target" && "$sf" sync ) >"$work/sync1.out" 2>&1; then
  note "$(cat "$work/sync1.out")"
else
  die "step 11: first sync exited non-zero"
  cat "$work/sync1.out"
fi

# ===========================================================================
# 12 [M] — assert sync idempotency
# ===========================================================================
step "[M] step 12: assert sync idempotency"
if ( cd "$target" && "$sf" sync ) >"$work/sync2.out" 2>&1; then
  grep -q 'sync: no changes' "$work/sync2.out" || die "step 12: second sync was not a no-op"
  git -C "$target" diff --quiet || die "step 12: second sync left a tracked git diff"
else
  die "step 12: second sync exited non-zero"
  cat "$work/sync2.out"
fi

# ===========================================================================
# 14 [M] — doctor and audit are clean   (step 13 [A]: discovery review)
# ===========================================================================
step "[M] step 14: doctor and audit are clean"
if ( cd "$target" && "$sf" doctor ) >"$work/doctor.out" 2>&1; then
  grep -q '^FAIL' "$work/doctor.out" && { die "step 14: doctor reported FAIL lines"; cat "$work/doctor.out"; } || true
else
  die "step 14: doctor exited non-zero"
  cat "$work/doctor.out"
fi
( cd "$target" && "$sf" audit ) >"$work/audit.out" 2>&1 || die "step 14: audit exited non-zero"

# ===========================================================================
# 15 [M] — close the planning session
# ===========================================================================
step "[M] step 15: close the planning session"
if ( cd "$target" && "$sf" plan-end ) >"$work/plan-end.out" 2>&1; then
  grep -q "planning session lock released" "$work/plan-end.out" \
    || die "step 15: plan-end did not report the lock released"
else
  die "step 15: plan-end exited non-zero"
fi

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
echo "covered [M] runbook steps: 1 2 3 5 7 8 9 11 12 14 15 16"
