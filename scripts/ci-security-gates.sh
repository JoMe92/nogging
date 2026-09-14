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
dependency_scan() { (cd "$root" && npm audit --audit-level=high); }

case "$gate" in
  secrets) secret_scan ;;
  links) link_scan ;;
  package) package_scan ;;
  dependencies) dependency_scan ;;
  all) secret_scan; link_scan; package_scan; dependency_scan ;;
  *) printf 'usage: %s {secrets|links|package|dependencies|all} [root]\n' "$0" >&2; exit 2 ;;
esac
