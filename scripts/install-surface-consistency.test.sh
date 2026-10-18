#!/usr/bin/env bash
# One install surface: the CLI help, scripts/bootstrap usage, README.md and
# docs/installation.md must agree. Offline; reads the sources and runs
# `bin/cli.js --help` and `scripts/bootstrap --help` (neither writes anything).
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
cd "$root"

if ! command -v node >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "ok   - skipped (node or python3 not installed)"
  echo "install surface consistency: ok"
  exit 0
fi

help_text=$(node bin/cli.js --help)
usage_text=$(bash scripts/bootstrap --help)
table_json=$(node -e "
  const { buildTable } = require('./bin/lib/preflight');
  process.stdout.write(JSON.stringify(buildTable('0.0.0').required.map(r => [r.name, r.min])));
")

HELP="$help_text" USAGE="$usage_text" TABLE="$table_json" python3 -I - "$root" <<'PY'
import json, os, re, sys
from pathlib import Path

root = Path(sys.argv[1])
help_text, usage_text = os.environ["HELP"], os.environ["USAGE"]
table = json.loads(os.environ["TABLE"])
docs = (root / "docs/installation.md").read_text()
readme = (root / "README.md").read_text()

failed = False
def check(desc, ok):
    global failed
    print(("ok   - " if ok else "FAIL - ") + desc)
    failed = failed or not ok

def squash(text):  # one-line, no backticks: wrapping and code spans never matter
    return re.sub(r"\s+", " ", text.replace("`", "")).strip()

def section(text, heading):
    m = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    return m.group(1) if m else ""

def sub_section(text, heading):  # ### or ####, up to the next heading of any level
    m = re.search(rf"^#{{3,4}} {re.escape(heading)}\n(.*?)(?=^#{{1,4}} |\Z)", text, re.M | re.S)
    return m.group(1) if m else ""

# --- CLI help options <-> installation guide flags ---------------------------
opts = {}  # long flag -> description (one line)
for line in help_text.split("Options:")[1].splitlines():
    m = re.match(r"\s+(?:-\w, )?(--[\w-]+)\s{2,}(.+)$", line)
    if m:
        opts[m.group(1)] = m.group(2).strip()
check("CLI help lists options", len(opts) >= 8)

flags_doc = sub_section(docs, "Flags")
bootstrap_doc = section(docs, "Fresh machine: `scripts/bootstrap`")
check("guide has a Flags section", bool(flags_doc))
check("guide has a bootstrap section", bool(bootstrap_doc))

def documented(text):
    out = set()
    for m in re.finditer(r"^- ((?:`-[^`]+`(?:, | / )?)+)", text, re.M):
        out.update(re.findall(r"`(--[\w-]+)[^`]*`", m.group(1)))
    return out

guide_flags = documented(flags_doc) | documented(bootstrap_doc)
for flag, desc in opts.items():
    check(f"{flag} is documented in the guide", flag in documented(flags_doc))
    check(f"{flag} uses the CLI help wording", squash(desc) in squash(flags_doc))

usage_flags = set(re.findall(r"--[\w-]+", usage_text))
for flag in sorted(guide_flags):
    check(f"guide flag {flag} exists in CLI help or bootstrap usage", flag in opts or flag in usage_flags)

# --- bootstrap usage flags <-> bootstrap section ------------------------------
for flag in sorted(usage_flags):
    check(f"bootstrap flag {flag} is documented under bootstrap", flag in documented(bootstrap_doc))

# --- prerequisites list == preflight table --------------------------------------
rows = re.findall(r"^\| ([^|]+?) \| ([\d.]+) \| (required|optional) \|$",
                  section(docs, "Prerequisites in the target repo"), re.M)
check("prerequisites table lists every preflight tool, in order, with its minimum",
      [[n, m] for n, m, _ in rows] == table)
check("prerequisites table marks every preflight tool required", all(r[2] == "required" for r in rows))

# --- README install commands appear verbatim in the guide -------------------------
cmds = []
for block in re.findall(r"```bash\n(.*?)```", section(readme, "Install"), re.S):
    cmds += [l.strip() for l in block.splitlines() if l.strip().startswith(("curl ", "npx "))]
check("README install section has install commands", len(cmds) >= 2)
for c in cmds:
    check(f"README command is in the guide: {c[:60]}", c in docs)

# --- help ends with the pointers ----------------------------------------------------
tail = help_text.strip().splitlines()[-2:]
check("help ends with a pointer to docs/installation.md", "docs/installation.md" in tail[0])
check("help ends with the pinned bootstrap", "raw.githubusercontent.com/JoMe92/nogging/v" in tail[1]
      and tail[1].rstrip().endswith("| bash"))

sys.exit(1 if failed else 0)
PY
echo "install surface consistency: ok"
