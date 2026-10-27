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
# Real tracking IDs belong only on Project & maintainers pages. Placeholders
# in samples stay; anything else that looks like a Bead or task ID, a weakness
# code or a design decision number is a leak of internal planning.
maintainer_pages = {"project.md"} | {
    path for path, fields in metadata.items() if fields.get("parent") == "Project & maintainers"}
placeholder_ids = {"SPEC-x", "SPEC-xx", "SPEC-xxx", "SPEC-yyy", "SPEC-abc", "SPEC-abc123", "TASK-ID"}
real_id = re.compile(r"\b(?:SPEC-[0-9a-z]{2,}|TASK-[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)+)\b")
internal_ref = re.compile(r"\b(?:W[0-9]{1,2}\b|[Dd]esign [Dd]ecision \d+|Decision \d+\b)")
site_only = {"index.md", "404.md", "getting-started.md", "concepts.md", "guides.md", "operations.md", "reference.md", "project.md"}
email = re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I)
image_re = re.compile(r"!\[([^\]]*)\]\(([^)\s]+)(?:\s+[^)]*)?\)")
link_re = re.compile(r"(?<!!)\[([^\]]+)\]\(([^)\s]+)(?:\s+[^)]*)?\)")
for rel, page in published:
    text = page.read_text()
    frontmatter = text.startswith("---\n")
    require(not frontmatter or rel in site_only, f"unexpected front matter in published page {rel}")
    if rel not in maintainer_pages:
        for found in real_id.findall(text):
            require(found in placeholder_ids, f"real tracking ID {found} in published page {rel}")
        for found in internal_ref.findall(text):
            require(False, f"internal planning reference {found!r} in published page {rel}")
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

# Brand assets load only from the site itself: no CDN, font service or other
# off-site script, stylesheet, font or image in includes, Sass, assets or pages.
offsite = re.compile(r"""(?ix)
    <script[^>]*\bsrc\s*=\s*["']?(?:https?:)?//
  | <link[^>]*\bhref\s*=\s*["']?(?:https?:)?//
  | @import\s+(?:url\()?\s*["']?(?:https?:)?//
  | url\(\s*["']?(?:https?:)?//
  | <(?:image|use)[^>]*\bhref\s*=\s*["']?(?:https?:)?//
""")
site_sources = [p for pattern in ("_includes/**/*", "_layouts/**/*", "_sass/**/*.scss", "assets/**/*.scss",
                                  "assets/**/*.css", "assets/**/*.js", "**/*.svg")
                for p in docs.glob(pattern) if p.is_file()]
for source in sorted(set(site_sources)) + [page for _, page in published]:
    rel = source.relative_to(docs).as_posix()
    match = offsite.search(source.read_text())
    require(match is None, f"{rel} loads an off-site asset: {match.group(0) if match else ''}")

# Every local asset an include or a Sass file references exists. Sass URLs are
# relative to the compiled stylesheets in assets/css/.
for include in sorted(docs.glob("_includes/**/*.html")):
    for target in re.findall(r"""['"](/[^'"{}]+)['"]\s*\|\s*(?:relative_url|absolute_url)""", include.read_text()):
        require((docs / target.lstrip("/")).is_file(),
                f"{include.relative_to(docs).as_posix()} references a missing asset: {target}")
for sass in sorted(docs.glob("_sass/**/*.scss")) + sorted(docs.glob("assets/**/*.scss")):
    for target in re.findall(r"""url\(\s*["']?([^"')\s]+)""", sass.read_text()):
        if re.match(r"(?i)^(data:|#|https?:|//)", target) or "#{" in target:
            continue
        resolved = (docs / target.lstrip("/")) if target.startswith("/") else (docs / "assets" / "css" / target)
        require(resolved.resolve().is_file(), f"{sass.relative_to(docs).as_posix()} references a missing asset: {target}")

# The head script reads and writes browser storage only inside try blocks, so a
# page with blocked storage still renders.
head_custom = docs / "_includes" / "head_custom.html"
require(head_custom.is_file(), "docs/_includes/head_custom.html is missing")
if head_custom.is_file():
    head_text = head_custom.read_text()
    for needle in ("prefers-color-scheme", "jtd.setTheme"):
        require(needle in head_text, f"head_custom.html does not use {needle}")
    stack = []
    for token in re.finditer(r"\btry\s*\{|\{|\}|\b(?:local|session)Storage\b", head_text):
        word = token.group(0)
        if word.startswith("try"):
            stack.append("try")
        elif word == "{":
            stack.append("block")
        elif word == "}":
            if stack:
                stack.pop()
        elif "try" not in stack:
            line = head_text.count("\n", 0, token.start()) + 1
            errors.append(f"head_custom.html line {line} uses {word} outside a try block")

# Brand colours (design Decision 5): every text, link and code token pair in
# both schemes keeps WCAG 2.1 AA contrast. Tokens are literal #RRGGBB lines.
def luminance(colour):
    channels = [int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    linear = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in channels]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

def contrast(first, second):
    high, low = sorted((luminance(first), luminance(second)), reverse=True)
    return (high + 0.05) / (low + 0.05)

text_pairs = [
    ("body-text-color", "body-background-color"), ("body-text-color", "sidebar-color"),
    ("body-text-color", "code-background-color"), ("body-text-color", "feedback-color"),
    ("body-text-color", "table-background-color"), ("body-text-color", "search-background-color"),
    ("body-text-color", "nogging-table-header-bg"),
    ("body-heading-color", "body-background-color"), ("body-heading-color", "sidebar-color"),
    ("code-linenumber-color", "code-background-color"),
    ("link-color", "body-background-color"), ("link-color", "sidebar-color"),
    ("link-color", "code-background-color"), ("link-color", "feedback-color"),
    ("nav-child-link-color", "sidebar-color"), ("nav-child-link-color", "feedback-color"),
    ("search-result-preview-color", "search-background-color"),
    ("nogging-text-secondary", "body-background-color"), ("nogging-text-secondary", "sidebar-color"),
    ("#FFFFFF", "btn-primary-color"),
]
for callout in ("note", "warning", "experimental"):
    text_pairs += [(f"nogging-{callout}-300", f"nogging-{callout}-bg"),
                   ("body-text-color", f"nogging-{callout}-bg"), ("link-color", f"nogging-{callout}-bg")]
scheme_pairs = {
    "nogging": text_pairs + [(f"nogging-syntax-{kind}", "code-background-color")
                             for kind in ("comment", "keyword", "name")],
    "nogging-dark": text_pairs + [("nogging-syntax-error", "code-background-color")],
}
schemes = {}
for scheme, pairs in scheme_pairs.items():
    scheme_file = docs / "_sass" / "color_schemes" / f"{scheme}.scss"
    entry = docs / "assets" / "css" / f"just-the-docs-{scheme}.scss"
    require(entry.is_file(), f"colour scheme {scheme} has no assets/css/{entry.name} entry")
    if not scheme_file.is_file():
        errors.append(f"colour scheme file _sass/color_schemes/{scheme}.scss is missing")
        continue
    tokens = dict(re.findall(r"(?m)^\$([a-z0-9-]+):\s*(#[0-9A-Fa-f]{6})\s*;", scheme_file.read_text()))
    schemes[scheme] = tokens
    for fg, bg in pairs:
        colours = [name if name.startswith("#") else tokens.get(name) for name in (fg, bg)]
        if None in colours:
            missing = [name for name, colour in zip((fg, bg), colours) if colour is None]
            errors.append(f"{scheme}: token ${missing[0]} is not a literal #RRGGBB value")
            continue
        ratio = contrast(*colours)
        require(ratio >= 4.5, f"{scheme}: {fg} {colours[0]} on {bg} {colours[1]} has contrast {ratio:.2f}:1, below 4.5:1")
if head_custom.is_file() and "nogging-dark" in schemes:
    critical = re.search(r"data-nogging-theme=\"dark\"\]\{[^}]*background-color:\s*(#[0-9A-Fa-f]{6})", head_custom.read_text())
    require(critical is not None and critical.group(1).upper() == schemes["nogging-dark"].get("body-background-color", "").upper(),
            "head_custom.html dark first-paint background must equal nogging-dark $body-background-color")

# Brand assets: Poppins with its licence, the mark in both variants, favicons.
for asset in ["assets/fonts/OFL.txt", "assets/images/nogging-mark.svg", "assets/images/nogging-mark-dark.svg",
              "assets/images/favicon.svg", "assets/images/favicon.ico", "assets/images/apple-touch-icon.png"] + [
              f"assets/fonts/poppins-latin-{weight}-normal.woff2" for weight in (400, 500, 600, 700)]:
    require((docs / asset).is_file() and (docs / asset).stat().st_size > 0, f"brand asset docs/{asset} is missing or empty")
footer_custom = docs / "_includes" / "footer_custom.html"
footer_text = footer_custom.read_text() if footer_custom.is_file() else ""
require("Nogging is released under the ISC License" in footer_text, "footer must say Nogging is released under the ISC License")
require("Copyright" not in footer_text, "footer must not copy the LICENSE copyright line")

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
