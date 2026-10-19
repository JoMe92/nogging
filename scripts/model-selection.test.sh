#!/usr/bin/env bash
# Model-selection rule table (TASK-MES-001).
#
# Covered:
#   - the shipped templates/model-selection.json passes `models check` and has
#     a Claude, Codex and Antigravity entry for every tier; the source
#     checkout's dogfood copy matches it;
#   - invalid tables (missing tier, Antigravity effort key, unsupported Codex
#     or Claude effort, flag-like/whitespace model, unknown key, unknown agent,
#     bad date, duplicate key, missing file) are refused naming the entry;
#   - `models --agent codex --tier standard` prints the Codex standard entry,
#     `agy` aliases `antigravity`, `--json` lookups, and nothing is written;
#   - docs/model-selection.md mirrors the shipped JSON table and the CLI help;
#   - the orchestrator prompt, /orchestrate and operating-model state the
#     mandatory tier procedure (TASK-MES-004);
#   - init scaffolds the table and update leaves a consumer edit byte-identical.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/.." && pwd)"
nogg="$here/nogg"
template="$repo_root/templates/model-selection.json"
work=$(mktemp -d)
out=$(mktemp)
trap 'rm -f "$out"; rm -rf "$work"' EXIT

fail=0
ok() { echo "ok   - $1"; }
bad() { echo "FAIL - $1"; cat "$out"; fail=1; }

make_root() {
  local r="$1"
  mkdir -p "$r/.nogging"
  git init -q "$r"
  cp "$repo_root/.nogging/config.json" "$r/.nogging/config.json"
  cp "$template" "$r/.nogging/model-selection.json"
}
# mutate <root> <python statement over `t`>
mutate() {
  python3 - "$1/.nogging/model-selection.json" "$2" <<'PY'
import json, sys
path, stmt = sys.argv[1], sys.argv[2]
t = json.load(open(path))
exec(stmt)
open(path, "w").write(json.dumps(t, indent=2) + "\n")
PY
}
models() { NOGGING_ROOT="$1" "$nogg" models "${@:2}"; }

r="$work/valid"; make_root "$r"
if models "$r" check >"$out" 2>&1 && grep -q "is valid" "$out"; then
  ok "shipped table passes models check"
else bad "shipped table passes models check"; fi

if python3 - "$template" >"$out" 2>&1 <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))
tiers = ("routine", "standard", "complex")
assert tuple(t["tiers"]) == tiers, t["tiers"].keys()
assert t["table_version"] and t["researched_at"]
for agent in ("claude", "codex", "antigravity"):
    for tier in tiers:
        entry = t["agents"][agent][tier]
        assert entry["model"], (agent, tier)
        assert ("effort" in entry) == (agent != "antigravity"), (agent, tier)
PY
then ok "every tier has a Claude, Codex and Antigravity entry"
else bad "every tier has a Claude, Codex and Antigravity entry"; fi

if cmp -s "$template" "$repo_root/.nogging/model-selection.json"; then
  ok "source checkout's .nogging/model-selection.json matches the template"
else echo "template and dogfood copy differ" >"$out"; bad "dogfood copy matches template"; fi

# Each invalid table must fail `models check` with a message naming the entry.
refuse() {
  local label="$1" stmt="$2" expect="$3" r="$work/bad-$RANDOM$RANDOM"
  make_root "$r"; mutate "$r" "$stmt"
  if models "$r" check >"$out" 2>&1; then bad "$label: accepted"; return; fi
  if grep -qF -- "$expect" "$out"; then ok "$label refused"; else bad "$label: message lacks '$expect'"; fi
}
refuse "missing tier" 'del t["agents"]["codex"]["complex"]' "agents.codex: missing key 'complex'"
refuse "missing tier definition" 'del t["tiers"]["routine"]' "tiers: missing key 'routine'"
refuse "Antigravity effort key" 't["agents"]["antigravity"]["standard"]["effort"] = "medium"' \
  "agents.antigravity.standard: 'effort' is not allowed"
refuse "unsupported Codex effort" 't["agents"]["codex"]["routine"]["effort"] = "turbo"' \
  "agents.codex.routine.effort: 'turbo' is not one of"
refuse "unsupported Claude effort" 't["agents"]["claude"]["complex"]["effort"] = "ultra"' \
  "agents.claude.complex.effort: 'ultra' is not one of"
refuse "missing Claude effort" 'del t["agents"]["claude"]["routine"]["effort"]' \
  "agents.claude.routine: missing key 'effort'"
refuse "flag-like model" 't["agents"]["codex"]["standard"]["model"] = "--yolo"' "agents.codex.standard.model"
refuse "whitespace model" 't["agents"]["claude"]["standard"]["model"] = "claude sonnet"' "agents.claude.standard.model"
refuse "empty model" 't["agents"]["antigravity"]["routine"]["model"] = ""' "agents.antigravity.routine.model"
refuse "unknown tier" 't["agents"]["claude"]["trivial"] = {"model": "x", "effort": "low"}' \
  "agents.claude: unknown key 'trivial'"
refuse "unknown agent" 't["agents"]["pi"] = t["agents"]["codex"]' "agents: unknown key 'pi'"
refuse "missing agent" 'del t["agents"]["antigravity"]' "agents: missing key 'antigravity'"
refuse "unknown top-level key" 't["extra"] = 1' "table: unknown key 'extra'"
refuse "bad table_version" 't["table_version"] = "yesterday"' "table_version: must be an ISO date"
refuse "unsupported schema" 't["schema"] = 2' "schema: unsupported value 2"

r="$work/dup"; make_root "$r"
python3 - "$r/.nogging/model-selection.json" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace('"schema": 1,', '"schema": 1, "schema": 1,', 1))
PY
if ! models "$r" check >"$out" 2>&1 && grep -q "duplicate key 'schema'" "$out"; then
  ok "duplicate key refused"; else bad "duplicate key refused"; fi

r="$work/missing"; make_root "$r"; rm "$r/.nogging/model-selection.json"
if ! models "$r" check >"$out" 2>&1 && grep -q "is missing" "$out" \
   && grep -q "templates/model-selection.json" "$out"; then
  ok "missing table refused with a remedy"; else bad "missing table refused with a remedy"; fi
if ! models "$r" --agent codex --tier routine >"$out" 2>&1; then
  ok "lookup refuses without a table"; else bad "lookup refuses without a table"; fi

# Lookups.
r="$work/valid"
before=$(cd "$r" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
if [[ "$(models "$r" --agent codex --tier standard)" == "standard  codex        model=gpt-6-luna effort=medium" ]]; then
  ok "models --agent codex --tier standard prints the Codex standard entry"
else models "$r" --agent codex --tier standard >"$out" 2>&1 || true; bad "codex standard lookup"; fi
if models "$r" --agent agy --tier complex >"$out" 2>&1 \
   && grep -q "^complex   antigravity  model=gemini-3.8-flash-high$" "$out"; then
  ok "agy is an alias for antigravity (no effort printed)"; else bad "agy alias"; fi
if models "$r" --agent agy --tier routine --json >"$out" 2>&1 && python3 - "$out" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))
assert e == {"agent": "antigravity", "tier": "routine", "model": "gemini-3.8-flash-low",
             "effort": None, "effort_source": None, "table_effort": None}, e
PY
then ok "--json single lookup"; else bad "--json single lookup"; fi
if models "$r" --json >"$out" 2>&1 && python3 - "$out" "$template" <<'PY'
import json, sys
assert json.load(open(sys.argv[1])) == json.load(open(sys.argv[2]))
PY
then ok "--json prints the full table"; else bad "--json prints the full table"; fi
if models "$r" --tier complex >"$out" 2>&1 && [[ $(grep -c '^complex ' "$out") == 3 ]] \
   && grep -q "table_version=2026-10-11" "$out"; then
  ok "--tier filter lists every agent's entry"; else bad "--tier filter"; fi
if models "$r" >"$out" 2>&1 && [[ $(grep -cE '^(routine|standard|complex) ' "$out") == 9 ]]; then
  ok "full table prints nine entries"; else bad "full table prints nine entries"; fi
if ! models "$r" --agent pi --tier routine >"$out" 2>&1; then
  ok "Pi has no table entry"; else bad "Pi has no table entry"; fi
if ! models "$r" --agent codex --tier trivial >"$out" 2>&1; then
  ok "unknown tier refused"; else bad "unknown tier refused"; fi
after=$(cd "$r" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha256sum)
if [[ "$before" == "$after" ]]; then ok "models writes nothing"; else
  diff <(echo "$before") <(echo "$after") >"$out" || true; bad "models writes nothing"; fi

# docs/model-selection.md mirrors the authoritative JSON.
if python3 - "$template" "$repo_root/docs/model-selection.md" >"$out" 2>&1 <<'PY'
import json, re, sys
t = json.load(open(sys.argv[1])); doc = open(sys.argv[2]).read()
rows = {}
for line in doc.splitlines():
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if line.startswith("|") and cells[0] in t["tiers"]:
        assert cells[0] not in rows, f"duplicate doc row {cells[0]}"
        rows[cells[0]] = [re.findall(r"`([^`]+)`", c) for c in cells[1:]]
assert set(rows) == set(t["tiers"]), f"doc tiers {sorted(rows)}"
for tier, (claude, codex, agy) in rows.items():
    a = t["agents"]
    assert claude == [a["claude"][tier]["model"], a["claude"][tier]["effort"]], (tier, claude)
    assert codex == [a["codex"][tier]["model"], a["codex"][tier]["effort"]], (tier, codex)
    assert agy == [a["antigravity"][tier]["model"]], (tier, agy)
assert f"`table_version` {t['table_version']}" in doc, "doc table_version"
assert f"`researched_at` {t['researched_at']}" in doc, "doc researched_at"
PY
then ok "docs/model-selection.md agrees with the shipped JSON"
else bad "docs/model-selection.md agrees with the shipped JSON"; fi

# The docs match the CLI help, and the orchestrator procedure (tier before
# every launch, escalation, no quota downgrade) is stated everywhere a fresh
# orchestrator reads it (TASK-MES-004).
"$nogg" session launch --help >"$work/launch-help" 2>&1 || true
"$nogg" models --help >"$work/models-help" 2>&1 || true
if python3 - "$template" "$repo_root" "$work/launch-help" "$work/models-help" >"$out" 2>&1 <<'PY'
import json, re, sys
from pathlib import Path
t = json.load(open(sys.argv[1])); root = Path(sys.argv[2])
launch_help = re.sub(r"\s+", " ", open(sys.argv[3]).read())
models_help = open(sys.argv[4]).read()
tiers = list(t["tiers"])
m = re.search(r"--tier TIER\s+model-selection tier \(([^)]*)\)", launch_help)
assert m and [x.strip() for x in m.group(1).split(",")] == tiers, f"launch --tier help: {m and m.group(1)}"
assert "--model still wins" in launch_help, "launch help: --model over tier"
assert "{" + ",".join(tiers) + "}" in models_help, "models --tier choices"
m = re.search(r"--agent \{([^}]*)\}", models_help)
assert m and set(m.group(1).split(",")) == set(t["agents"]) | {"agy"}, f"models --agent: {m and m.group(1)}"
assert "{check}" in models_help, "models check"
doc = (root / "docs/model-selection.md").read_text()
for snippet in ["scripts/nogg models check", "--agent agy", "--json", "session launch",
                "--tier standard", "explicit `--model` > tier > profile `model` > runtime default",
                "explicit `--effort` > project override > table > profile `model_reasoning_effort` > runtime default",
                "selection_tier", "tier=<tier>", "--agent pi", "claude-effort-forwarding",
                "quota never lowers a tier", "## Drift", "Product Owner Codex cost policy",
                "--model gpt-6-luna", "--model gpt-6.1-sol --effort low"]:
    assert snippet in doc, f"docs/model-selection.md lacks {snippet!r}"
for rel in [".nogging/launch-prompts/orchestrator.md", ".claude/commands/orchestrate.md",
            "docs/operating-model.md"]:
    text = re.sub(r"\s+", " ", (root / rel).read_text()).lower()
    for snippet in ["--tier <tier>", "scripts/nogg models --agent <agent> --tier <tier>",
                    "routine", "standard", "complex", "higher tier", "escalates one tier",
                    "quota never lowers a tier", "one-line reason", "product owner instruction",
                    "--model gpt-6-luna", "--model gpt-6.1-sol --effort low", "honest `--tier`",
                    "`tier_overrides`", "tracked work", "never replaces `--tier`",
                    "--tier <tier> --effort <level>", "interim form"]:
        assert snippet in text, f"{rel} lacks {snippet!r}"
PY
then ok "docs match the CLI help; orchestrator procedure stated in prompt, command and operating model"
else bad "docs match the CLI help; orchestrator procedure stated in prompt, command and operating model"; fi

# init scaffolds the table; update keeps a consumer edit byte-for-byte.
if command -v node >/dev/null; then
  c="$work/consumer"; mkdir -p "$c"; git init -q "$c"
  (cd "$c" && node "$repo_root/bin/cli.js" init --no-beads --no-hooks --no-systemd >/dev/null)
  if cmp -s "$template" "$c/.nogging/model-selection.json" \
     && test -f "$c/docs/nogging/model-selection.md"; then
    ok "init scaffolds .nogging/model-selection.json and the doc"
  else ls -la "$c/.nogging" >"$out" 2>&1; bad "init scaffolds the table"; fi
  mutate "$c" 't["agents"]["codex"]["standard"]["effort"] = "high"'
  printf ' \n' >>"$c/.nogging/model-selection.json"
  sum=$(sha256sum <"$c/.nogging/model-selection.json")
  (cd "$c" && node "$repo_root/bin/cli.js" update --no-hooks --no-systemd >/dev/null)
  if [[ "$(sha256sum <"$c/.nogging/model-selection.json")" == "$sum" ]]; then
    ok "update leaves an edited table byte-for-byte unchanged"
  else bad "update leaves an edited table byte-for-byte unchanged"; fi
  rm "$c/.nogging/model-selection.json"
  (cd "$c" && node "$repo_root/bin/cli.js" update --no-hooks --no-systemd >/dev/null)
  if cmp -s "$template" "$c/.nogging/model-selection.json"; then
    ok "update scaffolds an absent table"; else bad "update scaffolds an absent table"; fi
  if NOGGING_ROOT="$c" "$c/scripts/nogg" models check >"$out" 2>&1; then
    ok "installed nogg validates the scaffolded table"; else bad "installed nogg models check"; fi
else
  echo "SKIP: init/update scaffold checks (node unavailable)"
fi

exit "$fail"
