#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
python3 - "$root" <<'PY'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
docs = root / "docs"
config = (docs / "_config.yml").read_text()
errors = []

def require(ok, message):
    if not ok:
        errors.append(message)

plugins_match = re.search(r"(?m)^plugins:\n((?:  - [^\n]+\n)+)", config)
plugins = [line.strip()[2:] for line in plugins_match.group(1).splitlines()] if plugins_match else []
allowed = {
    "jekyll-remote-theme", "jekyll-include-cache", "jekyll-seo-tag",
    "jekyll-sitemap", "jekyll-relative-links", "jekyll-optional-front-matter",
    "jekyll-titles-from-headings",
}
require(plugins_match is not None and set(plugins) == allowed and len(plugins) == len(allowed),
        "plugins must be exactly the allow-listed GitHub Pages plugins")
require(bool(re.search(r"(?m)^remote_theme: just-the-docs/just-the-docs@v0\.12\.0$", config)),
        "remote_theme must pin Just the Docs v0.12.0")
require(bool(re.search(r"(?m)^permalink: pretty$", config)), "permalink must be pretty")
require(bool(re.search(r"(?m)^search_enabled: true$", config)), "search must be enabled")
require(bool(re.search(r"(?m)^color_scheme: nogging$", config)), "custom nogging color scheme must be selected")
require(bool(re.search(r"(?m)^\s+strip_title: false$", config)), "strip_title must be false")
require(bool(re.search(r"(?ms)^      path: \"\"\n    values:\n      layout: default$", config)),
        "published pages must use the theme default layout")
for label in ("GitHub repository", "Releases", "Discussions", "nav_external_links:", "title: Contributing"):
    require(label in config, f"missing header or Project & maintainers navigation item: {label}")

exclude_match = re.search(r"(?m)^exclude:\n((?:  - [^\n]+\n)+)", config)
excluded = [line.strip()[2:] for line in exclude_match.group(1).splitlines()] if exclude_match else []
expected_excluded = ["README.md", "acceptance/", "acceptance-report-template.md", "public-cutover.md"]
require(excluded == expected_excluded, f"exclude list must be exactly {expected_excluded}")

blocks = re.split(r"(?m)^  - scope:\n", config.split("defaults:\n", 1)[-1])
metadata = {}
for block in blocks:
    path_match = re.search(r"(?m)^      path: \"?(.*?)\"?$", block)
    if not path_match:
        continue
    path = path_match.group(1)
    if not path:
        continue
    values = block.split("    values:\n", 1)[-1]
    fields = {}
    for key, value in re.findall(r"(?m)^      ([a-z_]+):\s*(.*?)\s*$", values):
        fields[key] = value.strip('"')
    if path in metadata:
        errors.append(f"duplicate defaults scope for {path}")
    metadata[path] = fields

excluded_files = set(expected_excluded)
published = []
for page in sorted(docs.rglob("*.md")):
    rel = page.relative_to(docs).as_posix()
    if rel == "README.md" or rel == "acceptance-report-template.md" or rel == "public-cutover.md" or rel.startswith("acceptance/"):
        continue
    published.append((rel, page))
require(not any(rel in excluded_files or rel.startswith("acceptance/") for rel, _ in published),
        "an excluded page is being treated as published")

descriptions = {}
site_only = {"index.md", "404.md", "getting-started.md", "concepts.md", "guides.md", "operations.md", "reference.md", "project.md"}
email = re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I)
image_re = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)(?:\s+[^)]*)?\)")
link_re = re.compile(r"(?<!!)\[([^\]]+)\]\(([^)\s]+)(?:\s+[^)]*)?\)")
for rel, page in published:
    text = page.read_text()
    frontmatter = text.startswith("---\n")
    require(not frontmatter or rel in site_only, f"unexpected front matter in published page {rel}")
    fields = metadata.get(rel)
    require(fields is not None, f"{rel} has no _config.yml defaults placement")
    if fields is not None:
        desc = fields.get("description", "")
        require(bool(desc), f"{rel} has no description")
        require(len(desc) <= 160, f"{rel} description exceeds 160 characters")
        if desc:
            if desc in descriptions:
                errors.append(f"duplicate description on {rel} and {descriptions[desc]}")
            descriptions[desc] = rel

    clean = re.sub(r"(?ms)^```.*?^```\s*", "", text)
    require("{{" not in clean and "{%" not in clean, f"Liquid delimiters outside code in {rel}")
    privacy_text = text.replace("git@github.com:", "git-at-github.com:")
    require(not email.search(privacy_text), f"email address in published page {rel}")
    require(not re.search(r"\bMeier\b", text, re.I), f"owner surname in published page {rel}")

    for alt, target in image_re.findall(text):
        require(bool(alt.strip()), f"image in {rel} has no alt text: {target}")
        target = target.split("#", 1)[0].split("?", 1)[0]
        if not target or re.match(r"(?i)^(https?:|data:)", target):
            continue
        if target.startswith("/"):
            target_path = docs / target.lstrip("/").removeprefix("nogging/")
        else:
            target_path = (page.parent / target).resolve()
        require(target_path.is_relative_to(docs.resolve()), f"image escapes docs/ from {rel}: {target}")
        require(target_path.exists(), f"image asset is missing from {rel}: {target}")

    for label, target in link_re.findall(text):
        target = target.split("#", 1)[0].split("?", 1)[0]
        if not target or re.match(r"(?i)^(https?:|mailto:|tel:|javascript:)", target):
            continue
        if target.startswith("/"):
            target_path = docs / target.lstrip("/").removeprefix("nogging/")
        else:
            require(not target.startswith("../"), f"consumer-copied page {rel} links outside docs/: {target}")
            target_path = (page.parent / target).resolve()
        require(target_path.is_relative_to(docs.resolve()), f"published link escapes docs/ from {rel}: {target}")
        if target_path.suffix.lower() == ".md":
            rel_target = target_path.relative_to(docs.resolve()).as_posix() if target_path.is_relative_to(docs.resolve()) else ""
            require(target_path.exists(), f"published link from {rel} points to missing page: {target}")
            require(rel_target not in excluded_files and not rel_target.startswith("acceptance/"),
                    f"published link from {rel} points to excluded file: {target}")
        elif target_path.suffix:
            require(target_path.exists(), f"published link from {rel} points to missing asset: {target}")

# commands.md headings must match the live scripts/nogg --help output (offline).
import subprocess

def help_choices(*words):
    out = subprocess.run([str(root / "scripts" / "nogg"), *words, "--help"],
                         capture_output=True, text=True, check=False)
    usage = out.stdout.split("\n\n", 1)[0]
    found = re.search(r"\{([^}]+)\}", " ".join(usage.split()))
    return found.group(1).split(",") if found else []

commands_page = docs / "commands.md"
if not commands_page.exists():
    errors.append("docs/commands.md is missing")
else:
    headings = {2: [], 3: []}
    in_fence = False
    for line in commands_page.read_text().splitlines():
        if line.startswith("```"):
            in_fence = not in_fence
        match = None if in_fence else re.match(r"(#{2,3}) (.+?)\s*$", line)
        if match:
            headings[len(match.group(1))].append(match.group(2))
    top = help_choices()
    require(bool(top), "scripts/nogg --help lists no subcommands")
    require(headings[2] == top, f"commands.md ## headings {headings[2]} differ from nogg --help {top}")
    expected_sub = [f"{command} {sub}" for command in ("worktree", "pr", "orchestrator", "session")
                    for sub in help_choices(command)]
    actual_sub = headings[3]
    require(actual_sub == expected_sub,
            f"commands.md ### headings {actual_sub} differ from nogg --help {expected_sub}")

if errors:
    for error in errors:
        print(f"FAIL: {error}", file=sys.stderr)
    raise SystemExit(1)
print(f"PASS: docs site config and {len(published)} published Markdown pages")
PY
