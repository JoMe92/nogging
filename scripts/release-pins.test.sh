#!/usr/bin/env bash
# Every install pin names the package.json version: github:JoMe92/nogging#<tag>
# and raw.githubusercontent.com/JoMe92/nogging/<tag>/ in README.md and
# docs/installation.md, and NOGGING_TAG in scripts/bootstrap. The landing
# page's single install source docs/_data/install.yml carries the same pins
# and a tag key that equals the version. The same rule
# holds for every docs/*.md page. A <tag>, <new-tag> or vX.Y.Z placeholder is
# allowed; a bare main or develop is not. Offline.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source "$root/scripts/lib/test-env.sh"
cd "$root"

if ! command -v python3 >/dev/null 2>&1; then
  echo "ok   - skipped (python3 not installed)"
  echo "release pins: ok"
  exit 0
fi

python3 -I - "$root" <<'PY'
import json, re, sys
from pathlib import Path

root = Path(sys.argv[1])
version = json.loads((root / "package.json").read_text())["version"]
want = "v" + version
PLACEHOLDERS = {"<tag>", "<new-tag>", "vX.Y.Z"}

npx = re.compile(r"github:JoMe92/nogging#([^\s`'\")]+)")
raw = re.compile(r"raw\.githubusercontent\.com/JoMe92/nogging/([^/\s`'\")]+)/")
bare = re.compile(r"github:JoMe92/nogging(?![#\w/.-])")
tag_var = re.compile(r'^NOGGING_TAG="([^"]*)"', re.M)

def problems(name, text):
    out = []
    refs = [(m.group(1), "github:JoMe92/nogging#") for m in npx.finditer(text)]
    refs += [(m.group(1), "raw.githubusercontent.com/JoMe92/nogging/") for m in raw.finditer(text)]
    refs += [(m.group(1), "NOGGING_TAG") for m in tag_var.finditer(text)]
    for _ in bare.finditer(text):
        out.append(f"{name}: github:JoMe92/nogging names no tag")
    for ref, kind in refs:
        if ref.startswith("$"):  # a shell variable, pinned by NOGGING_TAG itself
            continue
        if ref in PLACEHOLDERS and kind != "NOGGING_TAG":
            continue
        if ref != want:
            out.append(f"{name}: {kind} names {ref!r}, want {want!r}")
    return out, len(refs)

failed = False
def check(desc, ok):
    global failed
    print(("ok   - " if ok else "FAIL - ") + desc)
    failed = failed or not ok

for rel in ("README.md", "docs/installation.md", "scripts/bootstrap"):
    found, n = problems(rel, (root / rel).read_text())
    check(f"{rel}: {n} pin(s) equal {want}" if not found else f"{rel}: " + "; ".join(found), not found and n > 0)

# The landing page's install data: its tag key, bootstrap and init lines.
install_rel = "docs/_data/install.yml"
install_text = (root / install_rel).read_text()
found, n = problems(install_rel, install_text)
tag_key = re.search(r'(?m)^tag:\s*(\S+)\s*$', install_text)
check(f"{install_rel}: {n} pin(s) equal {want}" if not found else f"{install_rel}: " + "; ".join(found), not found and n > 0)
check(f"{install_rel}: tag key equals {want}", tag_key is not None and tag_key.group(1) == want)

# Every other docs page may carry no pin at all, but any it carries must be
# the current tag or a placeholder.
docs_pages = sorted(p for p in (root / "docs").glob("*.md") if p.name != "installation.md")
stale = []
for page in docs_pages:
    found, _ = problems(page.relative_to(root).as_posix(), page.read_text())
    stale += found
check(f"{len(docs_pages)} docs pages pin only {want} or a placeholder" if not stale else "; ".join(stale), not stale)

# The check itself must catch a partial bump, a bare branch and a bad variable.
bad = [
    "npx github:JoMe92/nogging#v0.0.1 init",
    "curl https://raw.githubusercontent.com/JoMe92/nogging/main/scripts/bootstrap",
    "curl https://raw.githubusercontent.com/JoMe92/nogging/develop/scripts/bootstrap",
    'NOGGING_TAG="v0.0.1"',
    'NOGGING_TAG="<tag>"',
    "npx github:JoMe92/nogging init",
]
for i, text in enumerate(bad, 1):
    check(f"rejects stale or unpinned sample {i}", bool(problems("sample", text)[0]))
good = f"npx github:JoMe92/nogging#<tag> --version\nnpx github:JoMe92/nogging#<new-tag> update\nnpx github:JoMe92/nogging#{want} init\nNOGGING_TAG=\"{want}\""
check("accepts placeholders and the current tag", not problems("sample", good)[0])
check("rejects a stale install.yml tag key", re.search(r'(?m)^tag:\s*(\S+)\s*$', "tag: v0.0.1").group(1) != want)

sys.exit(1 if failed else 0)
PY
echo "release pins: ok"
