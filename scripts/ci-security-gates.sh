#!/usr/bin/env bash
set -euo pipefail

root=${2:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
gate=${1:-all}

secret_scan() {
  local hits
  hits=$(grep -RInE \
    --exclude-dir=.git --exclude-dir=node_modules --exclude='ci-security-gates.test.sh' \
    '(AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[pousr]_[A-Za-z0-9]{30,})' \
    "$root" 2>/dev/null || true)
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits" >&2
    printf 'credential-pattern scan failed\n' >&2
    return 1
  fi
}

link_scan() {
  python3 - "$root" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1]).resolve()
bad = []
for source in root.rglob("*.md"):
    if any(part in {".git", "node_modules"} for part in source.parts):
        continue
    text = source.read_text(encoding="utf-8")
    for target in re.findall(r"(?<!!)\[[^]]+\]\(([^)]+)\)", text):
        target = target.strip().split("#", 1)[0]
        if not target or re.match(r"(?:https?|mailto):", target) or target.startswith("#"):
            continue
        resolved = (source.parent / target).resolve()
        if root not in (resolved, *resolved.parents) or not resolved.exists():
            bad.append(f"{source.relative_to(root)} -> {target}")
if bad:
    print("\n".join(bad), file=sys.stderr)
    raise SystemExit("relative Markdown link scan failed")
PY
}

package_scan() { (cd "$root" && bash scripts/package-manifest.test.sh); }

# Advisories accepted as unfixable-for-now rather than ignored silently:
# every one must have a reason and a removal condition, checked below by its
# GHSA URL so a *different* high-severity finding still fails the gate.
#
# - GHSA-vfj7-8cjw-p6xm (braces, devDependency-only via @fission-ai/openspec's
#   fast-glob/micromatch): no patched braces release exists on the npm
#   registry as of 2026-10-03 (confirmed: `npm view braces versions` tops out
#   at 3.0.3; the advisory's own fix guidance resolves to an older,
#   differently-scoped @fission-ai/openspec release, not a real upgrade
#   path). Exposure is local/CI tooling only, never shipped to a Nogging
#   consumer. Remove this entry once a patched `braces` lands.
ACCEPTED_ADVISORIES=(
  "https://github.com/advisories/GHSA-vfj7-8cjw-p6xm"
)

dependency_scan() {
  local report
  report=$(cd "$root" && npm audit --audit-level=high --json) || true
  NOGGING_AUDIT_REPORT="$report" NOGGING_ACCEPTED_ADVISORIES="$(printf '%s\n' "${ACCEPTED_ADVISORIES[@]}")" \
    python3 <<'PY'
import json, os, sys
accepted = set(os.environ["NOGGING_ACCEPTED_ADVISORIES"].strip().splitlines())
try:
    data = json.loads(os.environ["NOGGING_AUDIT_REPORT"])
except ValueError:
    print("dependency vulnerability scan: npm audit did not return parseable JSON", file=sys.stderr)
    raise SystemExit(1)
unaccepted = []
for name, v in data.get("vulnerabilities", {}).items():
    if v.get("severity") not in ("high", "critical"):
        continue
    urls = {via.get("url") for via in v.get("via", []) if isinstance(via, dict) and via.get("url")}
    # A package with no direct advisory of its own (only pulled in through a
    # vulnerable dependency) is covered by that dependency's own entry.
    if urls and not (urls <= accepted):
        unaccepted.append((name, sorted(urls - accepted)))
if unaccepted:
    for name, urls in unaccepted:
        print(f"{name}: {', '.join(urls)}", file=sys.stderr)
    raise SystemExit("dependency vulnerability scan failed: unaccepted high/critical advisory")
PY
}

case "$gate" in
  secrets) secret_scan ;;
  links) link_scan ;;
  package) package_scan ;;
  dependencies) dependency_scan ;;
  all) secret_scan; link_scan; package_scan; dependency_scan ;;
  *) printf 'usage: %s {secrets|links|package|dependencies|all} [root]\n' "$0" >&2; exit 2 ;;
esac
