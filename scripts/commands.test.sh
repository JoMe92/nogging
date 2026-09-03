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

# --- 4. the canonical planning flow commits the spec before materialize --
#     (TASK-RIR-005) and the /plan step list matches docs/operating-model.md.
if python3 - <<'PY'
import re, sys

COMMIT = r"(as the `planning` writer|SPECFORGE_WRITER=planning)"
MATERIALIZE = r"materialize|materializes Beads"

bad = 0

# 1. Every surface that states the planning flow puts the planning commit
#    before materialize (the point of the change). First occurrence of each.
for f in (".claude/commands/plan.md", ".codex/prompts/plan.md",
          "docs/operating-model.md", "AGENTS.md", "templates/agents-block.md"):
    try:
        t = open(f).read()
    except OSError as e:
        print(f"MISSING {f}: {e}"); bad = 1; continue
    c = re.search(COMMIT, t)
    m = re.search(MATERIALIZE, t)
    if not c or not m:
        print(f"MISSING STEP {f}: commit={bool(c)} materialize={bool(m)}"); bad = 1
    elif c.start() > m.start():
        print(f"ORDER {f}: materialize appears before the planning commit"); bad = 1

# 2. The /plan step list matches docs/operating-model.md: the same ordered
#    sequence of mechanical steps in the /plan command file and in the
#    operating-model /plan row.
ORDER = ["plan-begin", r"\bvalidate\b", COMMIT, MATERIALIZE, "plan-end"]

def subseq_ok(text):
    pos = 0
    for pat in ORDER:
        m = re.search(pat, text[pos:])
        if not m:
            return False
        pos += m.end()
    return True

# the /plan row of the operating-model Commands table
row = next((ln for ln in open("docs/operating-model.md") if "`/plan` (`plan.md`)" in ln), "")
if not subseq_ok(row):
    print(f"OPMODEL /plan row order wrong: {row.strip()[:160]}"); bad = 1
if not subseq_ok(open(".claude/commands/plan.md").read()):
    print("plan.md step order does not match the canonical sequence"); bad = 1
if not subseq_ok(open(".codex/prompts/plan.md").read()):
    print("codex plan.md step order does not match the canonical sequence"); bad = 1

sys.exit(bad)
PY
then
  ok "planning flow: commit precedes materialize; /plan matches operating-model.md"
else
  bad "planning flow: commit-before-materialize order is inconsistent (see output above)"
fi

# --- 5. the resumption protocol + playbook exist (TASK-RIR-007) ----------
if python3 - <<'PY'
import re, sys
bad = 0
agents = open("AGENTS.md").read()
m = re.search(r"^##+ Resuming a run\b", agents, re.M)
if not m:
    print("AGENTS.md has no 'Resuming a run' section"); bad = 1
else:
    body = agents[m.start():m.start()+1200]
    if "specforge recover" not in body:
        print("AGENTS.md 'Resuming a run' does not run scripts/specforge recover"); bad = 1
    if not re.search(r"before[^.]*bd ready", body):
        print("AGENTS.md 'Resuming a run' must place recover before bd ready"); bad = 1
fr = open("docs/failure-recovery.md").read()
if not re.search(r"^##+ Resuming an interrupted run\b", fr, re.M):
    print("failure-recovery.md has no 'Resuming an interrupted run' playbook"); bad = 1
if "LIMBO" not in fr or not re.search(r"[Dd]o not re-implement|[Nn]ever re-implement", fr):
    print("failure-recovery.md playbook missing the LIMBO 'do not re-implement' rule"); bad = 1
sys.exit(bad)
PY
then
  ok "resumption protocol: AGENTS.md 'Resuming a run' + failure-recovery.md playbook present"
else
  bad "resumption protocol: missing or malformed (see output above)"
fi

# --- 6. the intent-breadcrumb rule is in the hard rules (TASK-RIR-008) ---
for f in AGENTS.md templates/agents-block.md; do
  if grep -qE 'progress: *<next step>|progress: *…' "$f" \
     && grep -qiE 'in_progress' "$f" && grep -qi 'breadcrumb' "$f"; then
    ok "$f carries the intent-breadcrumb hard rule"
  else
    bad "$f is missing the intent-breadcrumb hard rule (progress: <next step>)"
  fi
done

if [[ $fail -ne 0 ]]; then echo "command-file checks failed" >&2; exit 1; fi
echo "all command-file checks passed"
