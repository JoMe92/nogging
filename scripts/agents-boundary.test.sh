#!/usr/bin/env bash
# TASK-AGENT-011: the specialist boundary is enforced, not just described.
#
# 1. A delegated specialist context cannot write `openspec/`: the `PreToolUse`
#    guard (scripts/hooks/pre-tool-use-openspec-guard) exits 2 for an Edit/Write
#    under openspec/ when no planning lock is held — which is always the case in
#    a specialist context. It allows the write only while the planning lock
#    exists, and never interferes with a write outside openspec/.
# 2. No `.claude/agents/*.md` definition instructs a specialist to claim, close,
#    or commit a Bead: every line mentioning those verbs is a prohibition.
#
# Language-neutral: bash + coreutils + jq (the guard's own dependency). No
# network, no Beads/Dolt server.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
guard="$repo_root/scripts/hooks/pre-tool-use-openspec-guard"
agents_dir="$repo_root/.claude/agents"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# ===========================================================================
# 1. the PreToolUse guard blocks an openspec/ write from a specialist context
# ===========================================================================
root="$work/root"
mkdir -p "$root/openspec/changes/demo" "$root/src"
git -C "$root" init -q

run_guard() { # run_guard <file_path> ; prints nothing, sets $rc
  printf '{"tool_input":{"file_path":"%s"}}' "$1" \
    | CLAUDE_PROJECT_DIR="$root" "$guard" >"$work/guard.err" 2>&1
  rc=$?
}

# a specialist context holds no planning lock -> openspec/ write is blocked
run_guard "openspec/changes/demo/spec.md" || true
[[ "$rc" -eq 2 ]] \
  && ok "guard blocks a relative openspec/ path (exit 2) with no planning lock" \
  || { bad "guard did not block relative openspec/ path (rc=$rc)"; cat "$work/guard.err"; }
grep -qi 'planning session' "$work/guard.err" \
  && ok "guard explains openspec/ is writable only during a planning session" \
  || { bad "guard message did not mention the planning session"; cat "$work/guard.err"; }

run_guard "$root/openspec/project.md" || true
[[ "$rc" -eq 2 ]] \
  && ok "guard blocks an absolute openspec/ path too (exit 2)" \
  || { bad "guard did not block absolute openspec/ path (rc=$rc)"; cat "$work/guard.err"; }

# a write outside openspec/ is never touched
run_guard "src/feature.py" || true
[[ "$rc" -eq 0 ]] \
  && ok "guard allows a write outside openspec/ (exit 0)" \
  || { bad "guard blocked a non-openspec write (rc=$rc)"; cat "$work/guard.err"; }

# with a FRESH planning lock present the guard steps aside (planning session only)
mkdir -p "$root/.nogging/locks"
printf '{"pid":1,"host":"h","created_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
  >"$root/.nogging/locks/planning.lock"
run_guard "openspec/changes/demo/spec.md" || true
[[ "$rc" -eq 0 ]] \
  && ok "guard allows the openspec/ write while a fresh planning lock is held" \
  || { bad "guard still blocked with a fresh planning lock present (rc=$rc)"; cat "$work/guard.err"; }

# a STALE planning lock (older than planning_lock_ttl_seconds) no longer confers
# write permission — crash-resilience weakness W6 (SPEC-qjz / TASK-TWB-003)
cp "$repo_root/.nogging/config.json" "$root/.nogging/config.json" 2>/dev/null || \
  printf '{"planning_lock_ttl_seconds":7200}\n' >"$root/.nogging/config.json"
printf '{"pid":1,"host":"h","created_at":"2000-01-01T00:00:00+00:00"}\n' \
  >"$root/.nogging/locks/planning.lock"
run_guard "openspec/changes/demo/spec.md" || true
[[ "$rc" -eq 2 ]] \
  && ok "guard blocks an openspec/ write when the planning lock is stale (W6)" \
  || { bad "guard honoured a stale planning lock (rc=$rc)"; cat "$work/guard.err"; }
rm -f "$root/.nogging/locks/planning.lock"

# the boundary sentinel blocks regardless of the planning lock
printf '{"pid":1,"host":"h","created_at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" \
  >"$root/.nogging/locks/planning.lock"
printf '{"closed_at":"x","by":"test"}\n' >"$root/.nogging/locks/openspec.readonly"
run_guard "openspec/changes/demo/spec.md" || true
[[ "$rc" -eq 2 ]] \
  && ok "guard blocks an openspec/ write when the boundary sentinel is present" \
  || { bad "guard ignored the boundary sentinel (rc=$rc)"; cat "$work/guard.err"; }
rm -f "$root/.nogging/locks/planning.lock" "$root/.nogging/locks/openspec.readonly"

# ===========================================================================
# 2. no specialist definition instructs claim / close / commit of a Bead
# ===========================================================================
[[ -d "$agents_dir" ]] || { bad "$agents_dir missing"; }

expected_agents=(architect ui-ux-designer backend-engineer frontend-engineer code-reviewer test-runner)
for a in "${expected_agents[@]}"; do
  [[ -f "$agents_dir/$a.md" ]] && ok "specialist definition present: $a.md" \
    || bad "specialist definition missing: $a.md"
done

# A line that names a forbidden verb is allowed only as a prohibition: it must
# also carry a negation marker. This is the same technique scripts/commands.test.sh
# uses for the /discovery-review and /sync-now boundaries.
verb='\b(claim|claiming|clos(e|es|ing)|commit|committing|git push|--claim|--status|bd (update|close|ready))\b'
neg="never|not |no |n't|without|uncommitted|already[ -]claim|Lead Agent|Planning Agent|stays? with|reserved|do not"

lint_file() { # lint_file <path>
  local f="$1" offending
  offending=$(grep -nEi "$verb" "$f" | grep -viE "$neg" || true)
  if [[ -n "$offending" ]]; then
    bad "$(basename "$f"): non-prohibition mention of a Bead-ownership verb:"
    printf '        %s\n' "$offending"
  else
    ok "$(basename "$f"): every claim/close/commit mention is a prohibition"
  fi
}

for f in "$agents_dir"/*.md; do lint_file "$f"; done

# the lint must actually catch a violation
cat >"$work/bad-agent.md" <<'MD'
---
name: rogue
---
When you finish, claim the Bead with `bd update <id> --claim`, then run
`git commit` and `bd close <id>` yourself.
MD
if grep -nEi "$verb" "$work/bad-agent.md" | grep -viE "$neg" | grep -q .; then
  ok "lint flags a definition that tells the specialist to claim/commit/close"
else
  bad "lint failed to flag an obviously rogue definition"
fi

# every definition also states a single responsibility and its tool scope
for f in "$agents_dir"/*.md; do
  grep -qiE 'responsibilit|single responsibility' "$f" \
    && grep -qiE '^tools:' "$f" \
    && ok "$(basename "$f"): states a responsibility and a tools: scope" \
    || bad "$(basename "$f"): missing a responsibility line or a tools: field"
done

if [[ $fail -ne 0 ]]; then echo "specialist boundary checks failed" >&2; exit 1; fi
echo "all specialist boundary checks passed"
