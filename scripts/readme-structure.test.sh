#!/usr/bin/env bash
# README structure (TASK-RRI-001): a newcomer meets the purpose, the Quick
# Guide, installation and day-to-day use before reference material; install
# URLs are pinned to a released tag; the security link precedes full access;
# every relative link and #fragment resolves. Offline, no tools beyond python3.
set -euo pipefail
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# shellcheck source=lib/test-env.sh
source "$root/scripts/lib/test-env.sh"

python3 -I - "$root" <<'PY'
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
bad = []


def fail(msg):
    bad.append(msg)


readme = (root / "README.md").read_text()
lines = readme.splitlines()


def strip_fences(text):
    out, fenced = [], False
    for line in text.splitlines():
        if line.startswith("```"):
            fenced = not fenced
            out.append("")
        else:
            out.append("" if fenced else line)
    return out


prose = strip_fences(readme)

# --- head order: banner, "# Nogging", badge, tagline ----------------------
def first(pred):
    for i, line in enumerate(prose):
        if pred(line):
            return i
    return -1

banner = first(lambda l: l.startswith("![Nogging](docs/brand/nogging-banner.png)"))
title = first(lambda l: l == "# Nogging")
badge = first(lambda l: l.startswith("[![Nogging validation]"))
tagline = first(lambda l: l == "**Structure for a team of agents.**")
head = [banner, title, badge, tagline]
if min(head) < 0 or head != sorted(head):
    fail(f"head order is not banner, title, badge, tagline: {head}")

# --- intro paragraph: at most three sentences, before any ## heading -------
first_h2 = first(lambda l: l.startswith("## "))
intro, i = [], tagline + 1
while i < len(prose) and not prose[i].strip():
    i += 1
while i < first_h2 and prose[i].strip() and not prose[i].startswith(">"):
    intro.append(prose[i].strip())
    i += 1
intro_text = " ".join(intro)
if not intro_text:
    fail("no intro paragraph between the tagline and the first section")
elif len(re.findall(r"[.!?](?=\s|$)", intro_text)) > 3:
    fail("intro paragraph has more than three sentences")
if "(#safety-warning)" not in "\n".join(prose[i:first_h2]):
    fail("status blockquote does not link #safety-warning")

# --- section order ---------------------------------------------------------
def headings(level):
    return [l[len(level) + 1:].strip() for l in prose if l.startswith(level + " ")]

h2 = headings("##")
required = ["Quick Guide", "Install", "Use it day to day", "Safety warning",
            "Project status and audience", "Supported environments", "Concepts",
            "Documentation", "Developing Nogging", "Inspiration and related projects"]
pos = -1
for name in required:
    if name not in h2:
        fail(f"missing section: ## {name}")
        continue
    at = h2.index(name)
    if at < pos:
        fail(f"section out of order: ## {name}")
    pos = max(pos, at)
if "Tests and CI" in h2:
    fail("## Tests and CI must live in CONTRIBUTING.md, not README.md")


def subsections(section):
    out, inside = [], False
    for l in prose:
        if l.startswith("## "):
            inside = l[3:].strip() == section
        elif inside and l.startswith("### "):
            out.append(l[4:].strip())
    return out

if subsections("Install") != ["Fresh machine (scripts/bootstrap)", "Existing repository (npx init)"]:
    fail(f"Install subsections wrong: {subsections('Install')}")
if subsections("Use it day to day") != ["Plan a change", "Launch a Lead",
                                         "Watch and steer sessions", "Close out"]:
    fail(f"Use it day to day subsections wrong: {subsections('Use it day to day')}")

# --- Quick Guide: at most eight numbered steps, each with a command --------
steps, inside = [], False
for l in prose:
    if l.startswith("## "):
        inside = l[3:].strip() == "Quick Guide"
    elif inside and re.match(r"\d+\.\s", l):
        steps.append(l)
if not 1 <= len(steps) <= 8:
    fail(f"Quick Guide has {len(steps)} numbered steps (1-8 allowed)")
for s in steps:
    if not re.search(r"`[^`]+`", s):
        fail(f"Quick Guide step has no command: {s[:60]}")

# --- install URLs pinned to a v<semver> tag --------------------------------
semver = re.compile(r"v\d+\.\d+\.\d+$")
pins = re.findall(r"github:JoMe92/nogging#(\S+)", readme)
pins += re.findall(r"raw\.githubusercontent\.com/JoMe92/nogging/([^/\s]+)/", readme)
if not pins:
    fail("no pinned install URL found")
for ref in pins:
    if not semver.match(ref.rstrip("`.,)")):
        fail(f"install URL is not pinned to a release tag: {ref}")

# --- the security link comes before the first --full-access ----------------
link = readme.find("(docs/security-model.md)")
full = readme.find("--full-access")
if link < 0:
    fail("README does not link the security and threat model")
elif 0 <= full < link:
    fail("--full-access appears before the security and threat model link")

# --- public release: no pre-public wording, private-repository note -------
if re.search(r"pre-public|release candidate", readme, re.I):
    fail("README still says pre-public or release candidate")
status, inside = [], False
for l in lines:
    if l.startswith("## "):
        inside = l[3:].strip() == "Project status and audience"
    elif inside:
        status.append(l)
status_text = re.sub(r"\s+", " ", " ".join(status)).lower()
for needle in ("private", "full access", "safety warning", "--full-access",
               "background services", "(#safety-warning)"):
    if needle not in status_text:
        fail(f"Project status section lacks the private-repository note: {needle}")

# --- CI table lives in CONTRIBUTING.md -------------------------------------
if not re.search(r"^## Tests and CI$", (root / "CONTRIBUTING.md").read_text(), re.M):
    fail("CONTRIBUTING.md has no '## Tests and CI' section")


# --- relative links and fragments resolve ----------------------------------
def slug(heading):
    heading = re.sub(r"[`*_]", "", heading).strip().lower()
    heading = re.sub(r"[^\w\- ]", "", heading)
    return heading.replace(" ", "-")


def slugs(path):
    seen, out = {}, set()
    for l in strip_fences(path.read_text()):
        m = re.match(r"#{1,6}\s+(.*?)\s*#*$", l)
        if m:
            s = slug(m.group(1))
            n = seen.get(s, 0)
            seen[s] = n + 1
            out.add(s if n == 0 else f"{s}-{n}")
    return out


for m in re.finditer(r"\]\(([^)\s]+)\)", "\n".join(prose)):
    target, _, frag = m.group(1).partition("#")
    if re.match(r"[a-z][a-z0-9+.-]*:", target, re.I):
        continue
    path = (root / target) if target else (root / "README.md")
    if not path.exists():
        fail(f"link target does not exist: {m.group(1)}")
    elif frag and path.suffix == ".md" and frag not in slugs(path):
        fail(f"fragment does not match a heading: {m.group(1)}")

for line in bad:
    print("FAIL -", line)
if bad:
    sys.exit(1)
print("ok   - README structure, pins, security link order and links")
PY
