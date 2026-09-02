#!/usr/bin/env bash
# TASK-CMD-010: guard the operator command surface.
#
# 1. Every `.claude/commands/*.md` file the docs point at exists on disk.
# 2. `/discovery-review` and `/sync-now` carry no planning / openspec-write
#    step: no `plan-begin` / `plan-end` / `materialize` instruction, and every
#    mention of `openspec/` is a prohibition, never an instruction to write it.
# 3. `/plan`, by contrast, still drives `plan-begin` (catches a bad refactor).
#
# Language-neutral: bash + coreutils only, no network, no Beads/Dolt server.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
cd "$repo_root"

cmd_dir=".claude/commands"
fail=0
ok()  { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# --- 1. referenced command files exist ------------------------------------
doc_sources=(docs AGENTS.md README.md CLAUDE.md)
raw=$(grep -rhoE '\.claude/commands/[A-Za-z0-9_,{}.-]+\.md' "${doc_sources[@]}" 2>/dev/null | sort -u || true)

expand_ref() { # brace form .claude/commands/{a,b}.md -> one path per line
  local r="$1"
  case "$r" in
    *"{"*"}"*)
      local pre="${r%%\{*}" post inside
      inside="${r#*\{}"; inside="${inside%%\}*}"; post="${r##*\}}"
      local IFS=','; local p
      for p in $inside; do echo "${pre}${p}${post}"; done ;;
    *) echo "$r" ;;
  esac
}

referenced=""
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  referenced+="$(expand_ref "$ref")"$'\n'
done <<<"$raw"
referenced=$(printf '%s\n' "$referenced" | sort -u | sed '/^$/d')

if [[ -z "$referenced" ]]; then
  bad "no .claude/commands/*.md reference found in the docs"
else
  while IFS= read -r f; do
    if [[ -f "$f" ]]; then ok "referenced command file exists: $f"
    else bad "referenced command file missing: $f"; fi
  done <<<"$referenced"
fi

for name in plan discovery-review sync-now; do
  [[ -f "$cmd_dir/$name.md" ]] && ok "$cmd_dir/$name.md present" \
    || bad "$cmd_dir/$name.md missing"
done

# --- 2. discovery-review / sync-now carry no planning-write step ----------
neg='never|not |no |without|read-only|forbid'
for name in discovery-review sync-now; do
  path="$cmd_dir/$name.md"
  [[ -f "$path" ]] || { bad "$path missing (cannot inspect)"; continue; }

  if grep -qE 'plan-begin|plan-end|\bmaterialize\b' "$path"; then
    # a mention is allowed only as a prohibition — every such line must negate
    offending=$(grep -nE 'plan-begin|plan-end|\bmaterialize\b' "$path" | grep -viE "$neg" || true)
    if [[ -n "$offending" ]]; then
      bad "$name.md has a non-prohibition planning step: $offending"
    else
      ok "$name.md mentions plan-begin/materialize only to forbid it"
    fi
  else
    ok "$name.md has no plan-begin/plan-end/materialize step"
  fi

  if grep -qE 'openspec/' "$path"; then
    offending=$(grep -nE 'openspec/' "$path" | grep -viE "$neg" || true)
    if [[ -n "$offending" ]]; then
      bad "$name.md has a non-prohibition openspec/ reference: $offending"
    else
      ok "$name.md references openspec/ only to forbid writing it"
    fi
  else
    ok "$name.md does not reference openspec/"
  fi
done

# --- 3. plan.md still drives the planning lock ---------------------------
grep -q 'plan-begin' "$cmd_dir/plan.md" \
  && ok "plan.md drives scripts/specforge plan-begin" \
  || bad "plan.md lost its plan-begin step"
grep -q 'plan-end' "$cmd_dir/plan.md" \
  && ok "plan.md releases the lock with plan-end" \
  || bad "plan.md lost its plan-end step"

if [[ $fail -ne 0 ]]; then echo "command-file checks failed" >&2; exit 1; fi
echo "all command-file checks passed"
