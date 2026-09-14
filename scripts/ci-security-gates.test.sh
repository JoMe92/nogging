#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
cleanup() { case "$tmp" in /tmp/tmp.*) rm -r -- "$tmp" ;; esac; }
trap cleanup EXIT

expect_failure() {
  local name=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf 'FAIL - bad %s fixture passed\n' "$name" >&2
    exit 1
  fi
  printf 'ok   - bad %s fixture fails its gate\n' "$name"
}

mkdir -p "$tmp/secrets" "$tmp/links" "$tmp/package/scripts" "$tmp/dependencies/bin"
printf 'fake-test-token=AKIAXXXXXXXXXXXXXXXX\n' >"$tmp/secrets/bad.txt"
expect_failure secret "$root/scripts/ci-security-gates.sh" secrets "$tmp/secrets"

printf '[missing](does-not-exist.md)\n' >"$tmp/links/README.md"
expect_failure link "$root/scripts/ci-security-gates.sh" links "$tmp/links"

printf '{"files":["docs"]}\n' >"$tmp/package/package.json"
cp "$root/scripts/package-manifest.test.sh" "$tmp/package/scripts/"
git -C "$tmp/package" init -q
git -C "$tmp/package" add package.json scripts/package-manifest.test.sh
expect_failure package "$root/scripts/ci-security-gates.sh" package "$tmp/package"

printf '#!/usr/bin/env bash\nprintf "high vulnerability fixture\\n" >&2\nexit 1\n' \
  >"$tmp/dependencies/bin/npm"
chmod +x "$tmp/dependencies/bin/npm"
expect_failure dependency env PATH="$tmp/dependencies/bin:$PATH" \
  "$root/scripts/ci-security-gates.sh" dependencies "$tmp/dependencies"

"$root/scripts/ci-security-gates.sh" secrets "$root"
"$root/scripts/ci-security-gates.sh" links "$root"
printf 'CI security gate negative fixtures: ok\n'
